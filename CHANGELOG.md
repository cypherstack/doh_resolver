## 0.0.1

- First release.
- TXT lookups through DoH JSON APIs that accept only resolver-asserted DNSSEC
  answers.
- Caller-supplied transport port (`DohResolverTransport`) that receives the
  endpoint's media type.
- Google and Cloudflare presets for TXT format and media type.
