#!/usr/bin/env python3
"""Descarga y prepara los modelos de voz que van incluidos con la app.

Lo usa el workflow de GitHub Actions antes de compilar:

    python tool/incluir_modelos.py --perfil android --destino android/app/src/main/assets/incluidos
    python tool/incluir_modelos.py --perfil windows --destino build/windows/x64/runner/Release/incluidos

Deja en el destino:
    voces/<id>/...            paquetes Piper / Kokoro (sherpa-onnx)
    reconocimiento/<id>/...   Whisper (sólo la versión int8)
    manifest.json             lista de ficheros y una versión para la app

Los .tar.bz2 se guardan en --cache para no descargarlos en cada compilación.
"""

import argparse
import hashlib
import json
import os
import shutil
import sys
import tarfile
import time
import urllib.request

BASE = 'https://github.com/k2-fsa/sherpa-onnx/releases/download'

# Qué lleva cada plataforma. Android va más justo de tamaño (el APK y la
# copia en el teléfono): una voz Piper con hombre y mujer, Kokoro int8
# (53 voces, la mitad de tamaño) y Whisper base int8.
PERFILES = {
    'windows': {
        'voces': [
            'vits-piper-es_ES-davefx-medium',
            'vits-piper-es_ES-sharvard-medium',
            'kokoro-multi-lang-v1_0',
        ],
        'reconocimiento': ['sherpa-onnx-whisper-base'],
    },
    'android': {
        'voces': [
            'vits-piper-es_ES-sharvard-medium',
            'kokoro-int8-multi-lang-v1_0',
        ],
        'reconocimiento': ['sherpa-onnx-whisper-base'],
    },
}

CARPETA_RELEASE = {'voces': 'tts-models', 'reconocimiento': 'asr-models'}


def descargar(url, destino, intentos=6):
    if os.path.exists(destino) and os.path.getsize(destino) > 0:
        return
    parcial = destino + '.part'
    for i in range(intentos):
        try:
            with urllib.request.urlopen(url, timeout=60) as r, open(parcial, 'wb') as f:
                shutil.copyfileobj(r, f, 1 << 20)
            os.replace(parcial, destino)
            return
        except Exception as e:  # noqa: BLE001
            print(f'  fallo al descargar ({e}), reintento {i + 1}/{intentos}', file=sys.stderr)
            time.sleep(5 * (i + 1))
    raise SystemExit(f'No se pudo descargar {url}')


def recortar(categoria, carpeta):
    """Quita lo que la app no usa para ahorrar espacio."""
    for raiz, dirs, ficheros in os.walk(carpeta):
        for d in list(dirs):
            if d == 'test_wavs':
                shutil.rmtree(os.path.join(raiz, d))
                dirs.remove(d)
        if categoria == 'reconocimiento':
            # Whisper trae fp32 e int8; la app usa int8 si existe.
            for n in ficheros:
                if n.endswith('.onnx') and not n.endswith('.int8.onnx'):
                    int8 = n[:-len('.onnx')] + '.int8.onnx'
                    if int8 in ficheros:
                        os.remove(os.path.join(raiz, n))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--perfil', choices=sorted(PERFILES), required=True)
    ap.add_argument('--destino', required=True)
    ap.add_argument('--cache', default=os.path.join('.cache', 'modelos'))
    args = ap.parse_args()

    perfil = PERFILES[args.perfil]
    os.makedirs(args.cache, exist_ok=True)
    if os.path.isdir(args.destino):
        shutil.rmtree(args.destino)
    os.makedirs(args.destino)

    for categoria, ids in perfil.items():
        for mid in ids:
            url = f'{BASE}/{CARPETA_RELEASE[categoria]}/{mid}.tar.bz2'
            archivo = os.path.join(args.cache, f'{mid}.tar.bz2')
            print(f'{categoria}: {mid}')
            descargar(url, archivo)
            salida = os.path.join(args.destino, categoria)
            os.makedirs(salida, exist_ok=True)
            with tarfile.open(archivo, 'r:bz2') as t:
                t.extractall(salida, filter='data')
            carpeta = os.path.join(salida, mid)
            if not os.path.isdir(carpeta):
                raise SystemExit(f'{mid}: el archivo no trae la carpeta {mid}/')
            recortar(categoria, carpeta)

    ficheros = []
    for raiz, _, nombres in os.walk(args.destino):
        for n in nombres:
            ruta = os.path.join(raiz, n)
            rel = os.path.relpath(ruta, args.destino).replace(os.sep, '/')
            ficheros.append({'path': rel, 'size': os.path.getsize(ruta)})
    ficheros.sort(key=lambda f: f['path'])
    version = hashlib.sha1(json.dumps(ficheros).encode()).hexdigest()[:16]
    manifest = {
        'version': version,
        'voces': perfil['voces'],
        'reconocimiento': perfil['reconocimiento'],
        'files': ficheros,
    }
    with open(os.path.join(args.destino, 'manifest.json'), 'w', encoding='utf-8') as f:
        json.dump(manifest, f, indent=1)
    total = sum(f['size'] for f in ficheros)
    print(f'{len(ficheros)} ficheros, {total / 1e6:.0f} MB en {args.destino}')


if __name__ == '__main__':
    main()
