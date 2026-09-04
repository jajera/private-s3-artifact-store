# private-s3-artifact-store

CLI lab: keep S3 objects private behind regional gateway endpoints, publish in
Sydney, and replicate to Auckland.

## Docs

```bash
npm install
npm run dev
```

Same layout as the other johna.kiwi walkthroughs (Concepts, Deploy and operate,
Reference).

## Lab

```bash
export AWS_PROFILE=sandbox

./scripts/demo.sh up-shared
./scripts/demo.sh up-consumer syd
./scripts/demo.sh up-consumer akl
./scripts/demo.sh allowlist
./scripts/demo.sh publish
./scripts/demo.sh prove syd
./scripts/demo.sh prove akl
./scripts/demo.sh down
```

Pages live under `src/content/docs/`.

## Out of scope

- CloudFront / public CDN
- MRAP / one global hostname
- S3 interface endpoints for cross-Region reads
- Package-manager `repodata` (this lab uses plain objects)
