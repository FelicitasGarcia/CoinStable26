# pyth-coin-stable-front

Frontend en Next.js para crear/unirse a partidas y visualizar la UI del duelo.

## Requisitos

- Node.js 18+
- npm

## Variables de entorno

### Para correr el front (`npm run dev`)

Si vas a usar el flujo de crear partida con depósito on-chain (`depositA`), necesitás:

```env
BLOCKFROST_ID=...
PYTH_POLICY_ID=...
BACKEND_PKH=...
```

Además, el backend de Next lee `../pyth-coin-stable-validators/plutus.json`.

### Para interactuar con el validador

Para poder ejecutar el juego se necesitan las siguientes variables de entorno:

```env
BLOCKFROST_ID=...
PYTH_POLICY_ID=...
BACKEND_PKH=...
MNEMONIC="word1 word2 word3 ..."
PYTH_TOKEN=...
```

Notas:
- `PYTH_TOKEN` es obligatorio para `src/testFlow.mjs`.
- `src/depositA.mjs` no usa `PYTH_TOKEN`, pero puede coexistir en el mismo `.env`.

## Instalación

```bash
npm install
```

## Ejecutar en desarrollo

```bash
npm run dev
```

Abrir en navegador: `http://localhost:3000`

## Build de producción

```bash
npm run build
npm run start
```
