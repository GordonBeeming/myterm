import { createHash, generateKeyPairSync, randomBytes, sign } from "node:crypto";

const utf8 = (value) => Buffer.from(value, "utf8");
const sha256 = (bytes) => createHash("sha256").update(bytes).digest();
const encoded = (bytes) => bytes.toString("base64url");

function cbor(value) {
  const head = (kind, length) => length < 24 ? Buffer.from([kind | length]) : Buffer.from([kind | 24, length]);
  if (Buffer.isBuffer(value)) return Buffer.concat([head(0x40, value.length), value]);
  if (typeof value === "string") return Buffer.concat([head(0x60, utf8(value).length), utf8(value)]);
  if (typeof value === "number") return value >= 0 ? head(0, value) : head(0x20, -1 - value);
  return Buffer.concat([head(0xa0, value.size), ...[...value].flatMap(([key, entry]) => [cbor(key), cbor(entry)])]);
}

export class VirtualAuthenticator {
  keys = generateKeyPairSync("ed25519");
  credential = randomBytes(32);
  counter = 0;
  userHandle;

  register(options, origin) {
    this.userHandle = options.user.id;
    const clientDataJSON = this.clientData("webauthn.create", options, origin);
    const publicKey = Buffer.from(this.keys.publicKey.export({ format: "jwk" }).x, "base64url");
    const cose = cbor(new Map([[1, 1], [3, -8], [-1, 6], [-2, publicKey]]));
    const attestationData = Buffer.concat([Buffer.alloc(16), Buffer.from([0, this.credential.length]), this.credential, cose]);
    const authData = Buffer.concat([this.authData(options.rp.id, 0x45), attestationData]);
    const attestationObject = encoded(cbor(new Map([["fmt", "none"], ["attStmt", new Map()], ["authData", authData]])));
    return this.response({ clientDataJSON, attestationObject });
  }

  authenticate(options, origin) {
    this.counter++;
    const clientDataJSON = this.clientData("webauthn.get", options, origin);
    const authenticatorData = this.authData(options.rpId, 0x05);
    const signed = Buffer.concat([authenticatorData, sha256(Buffer.from(clientDataJSON, "base64url"))]);
    return this.response({
      clientDataJSON,
      authenticatorData: encoded(authenticatorData),
      signature: encoded(sign(null, signed, this.keys.privateKey)),
      userHandle: this.userHandle,
    });
  }

  clientData(type, options, origin) {
    return encoded(utf8(JSON.stringify({ type, challenge: options.challenge, origin, crossOrigin: false })));
  }

  authData(rpId, flags) {
    const counter = Buffer.alloc(4);
    counter.writeUInt32BE(this.counter);
    return Buffer.concat([sha256(utf8(rpId)), Buffer.from([flags]), counter]);
  }

  response(response) {
    const id = encoded(this.credential);
    return { id, rawId: id, type: "public-key", response, clientExtensionResults: {} };
  }
}
