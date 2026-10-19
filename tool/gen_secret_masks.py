#!/usr/bin/env python3
"""Prints XOR-split byte lists for lib/licensing/secrets.dart (Dart) and
android/app/src/main/kotlin/com/warsay/high/UnlockCodeRecovery.kt (Kotlin, signed bytes).

Usage: python3 tool/gen_secret_masks.py NAME VALUE   (VALUE: text, or hex:<hex bytes>)
Only needed when ROTATING a key. The seller keys and the resource master key must stay equal to what Bee
Seller / the encryptors use, otherwise existing codes and files stop working.
Never commit the plain VALUE anywhere (shell history included).
"""
import os, sys
name, value = sys.argv[1], sys.argv[2]
data = bytes.fromhex(value[4:]) if value.startswith('hex:') else value.encode()
a = os.urandom(len(data)); b = bytes(x ^ y for x, y in zip(data, a))
signed = lambda bs: ", ".join(str(x - 256 if x > 127 else x) for x in bs)
print('// Dart (secrets.dart)')
print(f'static const _{name}A = <int>[{", ".join(map(str, a))}];')
print(f'static const _{name}B = <int>[{", ".join(map(str, b))}];')
print('// Kotlin')
print(f'private val {name.upper()}_A = byteArrayOf({signed(a)})')
print(f'private val {name.upper()}_B = byteArrayOf({signed(b)})')
