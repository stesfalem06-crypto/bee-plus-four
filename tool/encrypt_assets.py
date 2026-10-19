#!/usr/bin/env python3
"""Encrypts 4's bundled study content for the APK (4 1.0.4+).

Reads every source listed in tool/content_assets.txt (notes, exams, matric questions + tips, exercises, tutor
index, coach/motivation, media images, 3D models, board codes) and writes one encrypted blob per file into
assets/c/ — the only content folder pubspec.yaml bundles. The plain sources stay in git and are never bundled.

Blob format (all integers big-endian):
    0..2  b'4CF'     magic
    3     1          format version
    4     flags      bit 0 = gzip'd before encryption (only when it saves >= 8 %)
    5..8  length     plain length (after gunzip)
    9..20 nonce      12 random bytes (fresh per file and per run)
    21..  ciphertext || 16-byte GCM tag      AES-256-GCM, AAD = bytes 0..8 + the asset path (UTF-8)
Blob name: first 32 hex chars of SHA-256("four-content-v1|" + asset path), so the APK shows no file names either.
The same rules live in lib/content/content_vault.dart and android/.../ContentChannel.kt.

Key: 32 random bytes in a file that is NOT in git (default /workspace/keys/four/content_key.bin, or
$FOUR_CONTENT_KEY_FILE). The app rebuilds it at runtime as  A xor B xor C:
    A = _contentA in lib/licensing/secrets.dart (Dart), B = CONTENT_B in GuardChannel.kt (Kotlin) — both public,
    C = written by this tool to .four_content_define.json (gitignored) and compiled in with
        flutter build ... --dart-define-from-file=.four_content_define.json
So the public repo alone does not give the key. (The APK does, to someone who reverse-engineers it.)

Usage:
    python3 tool/encrypt_assets.py            # encrypt (unchanged files are kept), write the define file
    python3 tool/encrypt_assets.py --verify   # decrypt every blob and compare with its source
Needs:  pip install cryptography
"""
import gzip, hashlib, json, os, re, struct, sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIST = os.path.join(ROOT, 'tool', 'content_assets.txt')
OUT = os.path.join(ROOT, 'assets', 'c')
DEFINE = os.path.join(ROOT, '.four_content_define.json')
MAGIC, VERSION, HDR = b'4CF', 1, 21


def key_file():
    return os.environ.get('FOUR_CONTENT_KEY_FILE', '/workspace/keys/four/content_key.bin')


def blob_name(path):
    return hashlib.sha256(('four-content-v1|' + path).encode()).hexdigest()[:32]


def sources():
    out = []
    for line in open(LIST, encoding='utf-8'):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        full = os.path.join(ROOT, line)
        if line.endswith('/'):
            if not os.path.isdir(full):
                sys.exit(f'missing folder {line}')
            for f in sorted(os.listdir(full)):
                if not f.startswith('.') and os.path.isfile(os.path.join(full, f)):
                    out.append(line + f)
        else:
            if not os.path.isfile(full):
                sys.exit(f'missing file {line}')
            out.append(line)
    return out


def _bytes_of(pattern, text, signed):
    m = re.search(pattern, text, re.S)
    if not m:
        sys.exit(f'mask not found: {pattern}')
    vals = [int(x) for x in re.findall(r'-?\d+', m.group(1))]
    return bytes((v + 256) % 256 for v in vals) if signed else bytes(vals)


def masks():
    dart = open(os.path.join(ROOT, 'lib/licensing/secrets.dart'), encoding='utf-8').read()
    kt = open(os.path.join(ROOT, 'android/app/src/main/kotlin/com/warsay/high/GuardChannel.kt'), encoding='utf-8').read()
    a = _bytes_of(r'_contentA = <int>\[([^\]]*)\]', dart, False)
    b = _bytes_of(r'CONTENT_B = byteArrayOf\(([^)]*)\)', kt, True)
    if len(a) != 32 or len(b) != 32:
        sys.exit('content masks must be 32 bytes')
    return a, b


def header(flags, n):
    return MAGIC + bytes([VERSION, flags]) + struct.pack('>I', n)


def seal(aes, path, plain):
    z = gzip.compress(plain, 9, mtime=0)
    flags, body = (1, z) if len(z) <= len(plain) * 0.92 else (0, plain)
    h = header(flags, len(plain))
    nonce = os.urandom(12)
    return h + nonce + aes.encrypt(nonce, body, h + path.encode())


def open_blob(aes, path, blob):
    if blob[:3] != MAGIC or blob[3] != VERSION:
        raise ValueError('bad header')
    flags, n = blob[4], struct.unpack('>I', blob[5:9])[0]
    body = aes.decrypt(blob[9:HDR], blob[HDR:], blob[:9] + path.encode())
    plain = gzip.decompress(body) if flags & 1 else body
    if len(plain) != n:
        raise ValueError('bad length')
    return plain


def main():
    verify = '--verify' in sys.argv
    kf = key_file()
    key = open(kf, 'rb').read()
    if len(key) != 32:
        sys.exit(f'{kf}: expected 32 bytes')
    aes = AESGCM(key)
    a, b = masks()
    c = bytes(x ^ y ^ z for x, y, z in zip(key, a, b))
    paths = sources()
    os.makedirs(OUT, exist_ok=True)
    names = {}
    for p in paths:
        n = blob_name(p)
        if n in names:
            sys.exit(f'name clash {p} {names[n]}')
        names[n] = p
    if verify:
        bad = 0
        for n, p in names.items():
            try:
                ok = open_blob(aes, p, open(os.path.join(OUT, n), 'rb').read()) == open(os.path.join(ROOT, p), 'rb').read()
            except Exception as e:  # noqa
                ok = False
            if not ok:
                bad += 1
                print('BAD', p)
        extra = [f for f in os.listdir(OUT) if not f.startswith('.') and f not in names]
        print(f'verified {len(names) - bad}/{len(names)} blobs, {len(extra)} stale')
        sys.exit(1 if bad or extra else 0)
    kept = made = 0
    src_bytes = out_bytes = 0
    for n, p in names.items():
        plain = open(os.path.join(ROOT, p), 'rb').read()
        dst = os.path.join(OUT, n)
        src_bytes += len(plain)
        try:
            if open_blob(aes, p, open(dst, 'rb').read()) == plain:
                kept += 1
                out_bytes += os.path.getsize(dst)
                continue
        except Exception:  # missing, other key, changed source
            pass
        blob = seal(aes, p, plain)
        with open(dst + '.tmp', 'wb') as f:
            f.write(blob)
        os.replace(dst + '.tmp', dst)
        made += 1
        out_bytes += len(blob)
    stale = [f for f in os.listdir(OUT) if not f.startswith('.') and f not in names]
    for f in stale:  # only blobs this tool made earlier
        os.remove(os.path.join(OUT, f))
    old = umask = os.umask(0o077)
    with open(DEFINE, 'w') as f:
        json.dump({'FOUR_CK': c.hex()}, f)
    os.umask(old)
    print(f'{len(names)} files: {made} encrypted, {kept} unchanged, {len(stale)} stale removed; '
          f'{src_bytes / 1e6:.1f} MB plain -> {out_bytes / 1e6:.1f} MB in assets/c/')


if __name__ == '__main__':
    main()
