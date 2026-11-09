# Fingerprint source

`src/algorithm.rs` and `src/signature_format.rs` adapt the corresponding files from [shazamio-core 2.1.0](https://github.com/shazamio/shazamio-core/tree/effeb115499c1bd87f5a13fc5eb99ac1e0b0a578/src/fingerprinting). The bundled copy keeps the PCM fingerprint and raw signature encoder. The iPhone supplies 16 kHz PCM and encodes the network payload, so this crate omits upstream’s file decoding, resampling, Python bindings, and request formatting. The source notices are in `LICENSE-MIT`.
