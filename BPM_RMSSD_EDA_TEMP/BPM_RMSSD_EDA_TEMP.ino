/*
  BPM_RMSSD_EDA_TEMP.ino — biosignal front-end for server.py

  Wiring (Arduino Uno):
    A0  PulseSensor PURPLE wire (signal). Red -> 5V, black -> GND.
    A1  Grove GSR VCC  — this pin is driven HIGH to power the module
    A2  Grove GSR SIG  — analog input (skin conductance)
    A3  Thermistor leg 1 — sense pin (internal pull-up = divider resistor)
    A4  Thermistor leg 2 — this pin is driven LOW to act as GND

  Thermistor note: with no external resistor, A3's internal pull-up (~35 kΩ)
  forms the voltage divider:  5V --[pull-up]-- A3 --[NTC]-- A4(LOW).
  The pull-up varies chip-to-chip (20–50 kΩ), so if the temperature reads
  offset, tune THERM_PULLUP below until a known temperature reads correctly.

  Prints one labeled line PER DETECTED HEARTBEAT at 115200 baud, e.g.
      BPM:72,RMSSD:41.2,EDA:5.34,TEMP:33.8
  which server.py parses directly (labeled format). No finger on the
  sensor -> no beats -> no output (the dashboard shows NO SIGNAL).

  No libraries required — the beat detector below is the classic
  PulseSensor threshold-tracking algorithm, polled from loop().
*/

// ---------------- pins ----------------
const int PIN_PULSE     = A0;   // PulseSensor purple wire
const int PIN_GSR_VCC   = A1;   // driven HIGH -> powers the Grove GSR module
const int PIN_GSR_SIG   = A2;   // Grove GSR SIG
const int PIN_THERM     = A3;   // thermistor sense (INPUT_PULLUP supplies the voltage)
const int PIN_THERM_GND = A4;   // driven LOW -> thermistor's ground leg

const unsigned long SAMPLE_US = 2000;   // pulse sampled every 2 ms (500 Hz)

// thermistor (10k NTC, beta 3950) read against the internal pull-up
const float THERM_R0     = 10000.0;     // ohms at 25 °C
const float THERM_BETA   = 3950.0;
const float THERM_PULLUP = 35000.0;     // internal pull-up estimate — TUNE THIS if temp reads offset
const float THERM_T0_K   = 298.15;      // 25 °C in kelvin

// ---------------- pulse / beat detection state ----------------
volatile int  BPM = 0;
bool newBeat = false;                   // set on each accepted beat; loop() prints one line per beat
unsigned long lastSampleUs = 0;
unsigned long lastBeatMs   = 0;
int  Peak = 512, Trough = 512, Thresh = 530, Amp = 100;
bool Pulse = false, firstBeat = true, secondBeat = false;

// inter-beat intervals for RMSSD (rolling buffer of the last 20 beats)
const int IBI_BUF = 20;
unsigned int ibiBuf[IBI_BUF];
int ibiCount = 0, ibiHead = 0;

void pushIBI(unsigned int ibi) {
  ibiBuf[ibiHead] = ibi;
  ibiHead = (ibiHead + 1) % IBI_BUF;
  if (ibiCount < IBI_BUF) ibiCount++;
}

// RMSSD = sqrt(mean(successive IBI differences squared)), in ms
float computeRMSSD() {
  if (ibiCount < 3) return 0.0;
  float sumsq = 0.0; int n = 0;
  // walk the buffer oldest -> newest
  int start = (ibiHead - ibiCount + IBI_BUF) % IBI_BUF;
  for (int i = 1; i < ibiCount; i++) {
    int a = ibiBuf[(start + i - 1) % IBI_BUF];
    int b = ibiBuf[(start + i) % IBI_BUF];
    float d = (float)b - (float)a;
    sumsq += d * d; n++;
  }
  return n > 0 ? sqrt(sumsq / n) : 0.0;
}

// classic PulseSensor threshold-tracking beat detector, one 500 Hz sample per call
void samplePulse() {
  int sig = analogRead(PIN_PULSE);
  unsigned long now = millis();
  unsigned long sinceBeat = now - lastBeatMs;

  // track peak & trough of the waveform
  if (sig < Thresh && sinceBeat > 250) {       // avoid dicrotic noise: wait 250 ms after a beat
    if (sig < Trough) Trough = sig;
  }
  if (sig > Thresh && sig > Peak) Peak = sig;

  if (sinceBeat > 250) {
    if (sig > Thresh && !Pulse) {              // upstroke crossed threshold -> a beat
      Pulse = true;
      unsigned int IBI = (unsigned int)sinceBeat;
      lastBeatMs = now;

      if (firstBeat) { firstBeat = false; secondBeat = true; return; }  // discard the first (no valid IBI yet)
      if (secondBeat) secondBeat = false;

      if (IBI > 300 && IBI < 2000) {           // 30–200 bpm plausibility gate
        pushIBI(IBI);
        // BPM from the average of the buffered IBIs (smoother than 60000/IBI)
        unsigned long sum = 0;
        for (int i = 0; i < ibiCount; i++) sum += ibiBuf[i];
        BPM = (int)(60000.0 / ((float)sum / ibiCount) + 0.5);
        newBeat = true;                        // report this beat from loop()
      }
    }
  }

  if (sig < Thresh && Pulse) {                 // downstroke: beat is over, re-arm
    Pulse = false;
    Amp = Peak - Trough;
    Thresh = Trough + Amp / 2;                 // threshold floats between peak & trough
    Peak = Thresh; Trough = Thresh;
  }

  if (sinceBeat > 2500) {                      // 2.5 s without a beat -> reset detector
    Thresh = 530; Peak = 512; Trough = 512;
    firstBeat = true; secondBeat = false;
    BPM = 0; ibiCount = 0; ibiHead = 0;
  }
}

// ---------------- GSR -> skin conductance (µS) ----------------
float readEDA() {
  long acc = 0;
  for (int i = 0; i < 10; i++) { acc += analogRead(PIN_GSR_SIG); delayMicroseconds(200); }
  float raw = acc / 10.0;
  if (raw >= 511.0) raw = 510.0;               // guard the Grove formula's divide
  // Seeed Grove GSR resistance formula, then conductance in microsiemens
  float rOhm = ((1024.0 + 2.0 * raw) * 10000.0) / (512.0 - raw);
  return 1e6 / rOhm;
}

// ---------------- thermistor -> °C ----------------
float readTempC() {
  long acc = 0;
  for (int i = 0; i < 10; i++) { acc += analogRead(PIN_THERM); delayMicroseconds(200); }
  float adc = acc / 10.0;
  if (adc <= 1.0 || adc >= 1022.0) return 0.0; // open/short -> report an obviously-bad 0
  // divider: 5V --[internal pull-up]-- A3 --[NTC]-- A4(LOW)
  //   =>  R_ntc = R_pullup * adc / (1023 - adc)
  float rNtc = THERM_PULLUP * adc / (1023.0 - adc);
  float tK = 1.0 / (1.0 / THERM_T0_K + log(rNtc / THERM_R0) / THERM_BETA);
  return tK - 273.15;
}

// ---------------- main ----------------
void setup() {
  Serial.begin(115200);

  pinMode(PIN_GSR_VCC, OUTPUT);  digitalWrite(PIN_GSR_VCC, HIGH);  // A1 = 5V rail for the GSR module
  pinMode(PIN_GSR_SIG, INPUT);

  pinMode(PIN_THERM_GND, OUTPUT); digitalWrite(PIN_THERM_GND, LOW); // A4 = ground leg of the thermistor
  pinMode(PIN_THERM, INPUT_PULLUP);                                 // pull-up doubles as the divider resistor

  lastBeatMs = millis();
}

void loop() {
  unsigned long nowUs = micros();
  if (nowUs - lastSampleUs >= SAMPLE_US) {     // 500 Hz pulse sampling
    lastSampleUs = nowUs;
    samplePulse();
  }

  if (newBeat) {                               // one line per detected heartbeat
    newBeat = false;
    float rmssd = computeRMSSD();
    float eda   = readEDA();
    float tempC = readTempC();

    Serial.print("BPM:");   Serial.print(BPM);
    Serial.print(",RMSSD:"); Serial.print(rmssd, 1);
    Serial.print(",EDA:");   Serial.print(eda, 2);
    Serial.print(",TEMP:");  Serial.println(tempC, 1);
  }
}
