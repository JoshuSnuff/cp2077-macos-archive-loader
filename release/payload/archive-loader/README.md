# Installed payload contract

An assembled release populates this directory as follows:

```text
archive-loader/
├── bin/
│   └── patcher
├── scripts/
├── gamefiles/
└── manifests/
```

The installer will copy this tree to `<game>/archive-loader/`. Mutable
directories such as `pristine/`, `backups/`, `state/`, and `logs/` are created
only by the future transactional installer and are never part of a release
payload.
