# Pass Service

Signs Wallet passes for Rapid Wallet. This is a development server: it runs on your Mac and serves a development iPhone on the same network.

It uses Apple's [Pass Builder](https://github.com/apple/pass-builder) to build and sign passes, and Hummingbird 2 for HTTP. It keeps no state, and it never logs request bodies.

## One-time setup in the Apple Developer portal

You need an Apple Developer Program membership on team `B2AA43A5CZ`. Keep every file below outside this repo. These commands use `~/.rapid-wallet/pass-certs`.

### 1. Register the Pass Type ID

1. Go to [Certificates, IDs & Profiles > Identifiers](https://developer.apple.com/account/resources/identifiers/list/passTypeId).
2. Click **+**, choose **Pass Type IDs**, and click **Continue**.
3. Enter the description `Rapid Wallet tag` and the identifier `pass.dev.scalexy.rapidwallet.tag`.
4. Click **Continue**, then **Register**.

### 2. Create a private key and CSR

```sh
mkdir -p ~/.rapid-wallet/pass-certs
chmod 700 ~/.rapid-wallet/pass-certs
cd ~/.rapid-wallet/pass-certs

openssl genrsa -out pass-key.pem 2048
chmod 600 pass-key.pem
openssl req -new -key pass-key.pem -out pass.csr -subj "/CN=Rapid Wallet Pass Type ID/O=ScaleXY"
```

Leave the key unencrypted, because the service can't read a key with a passphrase. Anyone who gets `pass-key.pem` can sign passes as your team.

### 3. Download the certificate

1. In [Certificates](https://developer.apple.com/account/resources/certificates/list), click **+**.
2. Under **Services**, choose **Pass Type ID Certificate** and click **Continue**.
3. Enter a name, select `pass.dev.scalexy.rapidwallet.tag`, and click **Continue**.
4. Upload `pass.csr`, click **Continue**, then **Download**.
5. Move the file to `~/.rapid-wallet/pass-certs/pass.cer`.

### 4. Get the WWDR G4 intermediate

```sh
cd ~/.rapid-wallet/pass-certs
curl -fsSLO https://www.apple.com/certificateauthority/AppleWWDRCAG4.cer
```

### 5. Convert both certificates to PEM

```sh
cd ~/.rapid-wallet/pass-certs
openssl x509 -inform DER -in pass.cer -out pass-cert.pem
openssl x509 -inform DER -in AppleWWDRCAG4.cer -out wwdr.pem
```

Check the result:

```sh
openssl x509 -in pass-cert.pem -noout -subject -issuer -enddate
openssl x509 -in wwdr.pem -noout -subject
```

The subject of `pass-cert.pem` must show `UID=pass.dev.scalexy.rapidwallet.tag` and `OU=B2AA43A5CZ`. Its issuer must match the subject of `wwdr.pem`. If it names a different WWDR generation, download that intermediate from [Apple's certificate authority page](https://www.apple.com/certificateauthority/) instead.

### 6. Create a token

```sh
openssl rand -hex 32 > ~/.rapid-wallet/pass-certs/token
chmod 600 ~/.rapid-wallet/pass-certs/token
```

## Run the service

```sh
cd PassService
export PASS_CERT_PEM=~/.rapid-wallet/pass-certs/pass-cert.pem
export PASS_KEY_PEM=~/.rapid-wallet/pass-certs/pass-key.pem
export WWDR_CERT_PEM=~/.rapid-wallet/pass-certs/wwdr.pem
export PASS_SERVICE_TOKEN="$(cat ~/.rapid-wallet/pass-certs/token)"
swift run --scratch-path /tmp/rw-pass pass-service
```

The service listens on `0.0.0.0:8787`. It refuses to start if a required variable is missing, if the key doesn't match the certificate, or if the certificate isn't for this Pass Type ID and team.

| Variable | Required | Meaning |
|---|---|---|
| `PASS_CERT_PEM` | Yes | Pass Type ID certificate: a file path or inline PEM |
| `PASS_KEY_PEM` | Yes | Its unencrypted private key: a file path or inline PEM |
| `WWDR_CERT_PEM` | Yes | WWDR intermediate: a file path or inline PEM |
| `PASS_SERVICE_TOKEN` | Yes | Bearer token the app must send |
| `PASS_SERVICE_PORT` | No | Listening port. Defaults to `8787`. `0` picks a free port. |
| `PASS_SERVICE_TMPDIR` | No | Directory for short-lived signing files. Defaults to the user's temp directory. |

## Connect the app

Your Mac and iPhone must be on the same network.

1. Find your Mac's address. Prefer the `.local` name, because it survives DHCP changes:

   ```sh
   echo "http://$(scutil --get LocalHostName).local:8787"
   ipconfig getifaddr en0    # The LAN IP, if the name doesn't resolve
   ```

2. Check it from the Mac:

   ```sh
   curl "http://$(scutil --get LocalHostName).local:8787/healthz"    # Prints ok
   ```

3. In the app, open Settings. Under **Wallet Pass Service**, enter that URL and the token from `~/.rapid-wallet/pass-certs/token`.
4. When iOS asks for Local Network access, allow it.
5. If macOS asks whether `pass-service` may accept incoming connections, allow it.

This is plain HTTP, so the token and any QR content cross your network unencrypted. Use a network you trust.

## API

### `GET /healthz`

Returns `200` with the body `ok`. It needs no token.

### `POST /v1/passes`

Send `Authorization: Bearer <token>` and this JSON:

```json
{
  "serial": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
  "kind": "normal",
  "title": "Office Wi-Fi",
  "details": "Normal",
  "qr": "https://example.com"
}
```

| Field | Rule |
|---|---|
| `serial` | A UUID |
| `kind` | `normal` or `signer` |
| `title` | 1 to 64 characters, not blank |
| `details` | Up to 128 characters. It gets its own field unless it's empty or repeats the type name. |
| `qr` | Optional, 1 to 1024 UTF-8 bytes. The pass has a QR code only when this is present. |

| Status | Meaning |
|---|---|
| `200` | The signed pass, as `application/vnd.apple.pkpass` |
| `400` | Invalid JSON or a field that breaks a rule above |
| `401` | Missing or wrong token |
| `413` | Body over 16 KB |
| `500` | Signing failed |

## Tests

```sh
swift build --scratch-path /tmp/rw-pass
swift test --scratch-path /tmp/rw-pass
```

The tests run the real server on a random port, using credentials from `scripts/make-test-cert.sh`. They need `openssl` with `cms` support on your `PATH`.

That script creates a throwaway chain in a new temp directory, for tests only. **Wallet will reject passes signed with these credentials,** because they don't chain to Apple. They expire after two days. Never commit them.

`swift scripts/make-assets.swift` regenerates the pass images.

## Not yet tried on a device

No Pass Type ID certificate existed when this was built, so no pass has been loaded into Wallet.

- **The link is unverified.** There's no App Store ID yet, so `associatedStoreIdentifiers` and `appLaunchURL` can't work. The back of the pass has an `attributedValue` link to `rapidwallet://tag/<serial>` instead. We don't know that Wallet opens a custom URL scheme from a back field, so try it on a device.
- **Pass Builder is an early preview.** The dependency is pinned to one revision because the repo has no tags. Its output adds a `tooling.json` file and a random `_id` to each field in `pass.json`. Check that Wallet accepts these on the first real pass.
