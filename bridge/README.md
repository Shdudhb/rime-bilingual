# Rime bilingual native bridge

This x64 Lua 5.4 `cdylib` is the non-blocking boundary between librime-lua and
the loopback Translation Helper. It dynamically resolves Lua symbols from the
already-loaded `rime.dll`; it must not be packaged with a separate Lua DLL.

Build:

```powershell
cargo test --manifest-path bridge/Cargo.toml
cargo build --release --manifest-path bridge/Cargo.toml
```

The release artifact is
`bridge/target/release/rime_bilingual_bridge.dll`. The installer should copy it
to `%APPDATA%\Rime\rime-bilingual\native\rime_bilingual_bridge.dll`.

The supported ABI is Weasel 0.17.4 / librime 1.13.1 x64. `configure` additionally
checks the caller-provided SHA-256 pin for `rime.dll`; no file is read on the
Rime hot path.

