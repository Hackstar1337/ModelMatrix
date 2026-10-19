# Controller Fuzzing Fixtures

`ModelMatrixControllerTests` covers these parser and request boundaries with native Swift fixtures.

Covered boundaries:

- declarative `.env` profile parsing
- JSON profile normalization
- profile-derived URL validation
- controller JSON request parsing
- non-HTTP URL rejection before network calls

Run only this harness:

```sh
swift test --filter ModelMatrixControllerTests
```

The harness writes only to temporary directories.
