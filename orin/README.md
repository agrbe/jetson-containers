# orin/

Ferramentas do build da imagem CUDA (`bedrock`) no Jetson AGX Orin (JetPack 7.2).
A lista de pacotes fica em `packages.txt` (um por linha, `#` comenta); os pins de
versão vêm do `.env` da raiz (exemplo em `.env.orin`).

Ordem de uso (a partir da raiz do repo). `audit.py` e `download.sh` precisam dos
servidores no ar: use `--keep-running` no build ou rode `launch_pypi.sh` de novo.

1. `./launch_pypi.sh` — sobe o devpi e o servidor APT locais e grava as URLs no `.env`.
2. `orin/lint.py [-v]` — confere `packages.txt` antes de buildar (pins perdidos, ARGs vazios, clones sem ref). Sai com 1 se houver ERROR.
3. `orin/build_image.sh [--simulate] [--keep-running] [-- <args do jetson-containers build>]` — builda a cadeia; sobe os servidores se preciso e os derruba no fim. Após um build bem-sucedido roda `orin/clean.sh`, exceto com `--keep-running`.
4. `orin/audit.py [--log-dir logs/<run>] [-v]` — audita as imagens de estágio: drift em relação aos pins, flip-flops, `uv pip check`, wheels locais ausentes no devpi.
5. `orin/download.sh [--wheels|--tarballs] [--dry-run]` — copia os wheels (devpi) e tarballs (APT) locais para `dist/`, com verificação de sha256.
6. `orin/clean.sh [--cache|--images|--nuke] [--dry-run]` — libera disco (imagens, cache do BuildKit, caches uv/pip); para os servidores.

Apoio:

- `orin/export_image.sh <imagem[:tag]> [--output <dir>]` — exporta a imagem para `.tar` com sha256 e Id.
- `orin/dep_graph.py [--focus X] [--what-if DIST[==VER]]` — grafo de dependências da imagem final e simulação de bumps (`uv pip compile`); use antes de mudar um pin.
- `orin/COMPATIBILITY.md` — versões, acoplamentos e workarounds por lib; atualize ao mudar um pin em `packages.txt`.
- `orin/package_list.py` — módulo comum dos scripts Python (`python3 orin/package_list.py` roda o self-check).
- `./stop_pypi.sh` — para os servidores manualmente (útil após `--keep-running`).
