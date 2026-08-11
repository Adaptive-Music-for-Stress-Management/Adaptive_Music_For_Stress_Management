import os
import sys
import json
import io
import zipfile
import urllib.request
import urllib.error

# ---- destinations: relative to THIS script (works in any clone) --------------
HERE   = os.path.dirname(os.path.abspath(__file__))
OUT    = os.path.join(HERE, "outputs")
MUSIC  = os.path.join(HERE, "suno_ai_songs")
SONGS_ZIP   = "suno_ai_songs.zip"   # a zip whose ROOT contains calm/ neutral/ elevated/


def _download(url, dest):
    print(f"  - {os.path.basename(dest)} ... ", end="", flush=True)
    try:
        urllib.request.urlretrieve(url, dest)
        print(f"done ({os.path.getsize(dest):,} bytes)")
        return True
    except urllib.error.HTTPError as e:
        print(f"FAILED (HTTP {e.code}) — is the Release tag '{TAG}' published with this asset?")
    except Exception as e:
        print(f"FAILED ({e})")
    return False


def main():
    print(f"Fetching assets from  {BASE}\n")

    # --- songs (optional) -> ./suno_ai_songs ---
    print("\nSongs -> suno_ai_songs/")
    os.makedirs(MUSIC, exist_ok=True)
    try:
        print(f"  - {SONGS_ZIP} ... ", end="", flush=True)
        data = urllib.request.urlopen(f"{BASE}/{SONGS_ZIP}").read()
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            z.extractall(MUSIC)
        n = sum(len(files) for _, _, files in os.walk(MUSIC))
        print(f"extracted ({n} files)")
    except Exception as e:
        print(f"skipped ({e})")
        print("    (local music will be empty until songs are added; the app still runs in LOCAL mode without them)")

    

if __name__ == "__main__":
    main()
