# Prints a DPoP proof (RFC 9449) for one request: python3 dpop.py <key.pem> [METHOD],
# with the URL on the first line of stdin and the access token on the second.
# With no token on stdin, it prints the proof of a token request, which has no `ath`.
# An Ed25519 key signs EdDSA (RFC 8037); a P-256 key signs ES256.
import base64, hashlib, sys, time, uuid
import jwt
from cryptography.hazmat.primitives.asymmetric import ed25519
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat, load_pem_private_key


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def algorithm(key):
    return "EdDSA" if isinstance(key, ed25519.Ed25519PrivateKey) else "ES256"


def public_jwk(key):
    if isinstance(key, ed25519.Ed25519PrivateKey):
        return {"crv": "Ed25519", "kty": "OKP", "x": b64(key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw))}
    nums = key.public_key().public_numbers()
    return {"crv": "P-256", "kty": "EC", "x": b64(nums.x.to_bytes(32, "big")), "y": b64(nums.y.to_bytes(32, "big"))}


def dpop_proof(key_pem, method, url, token=None):
    key = load_pem_private_key(key_pem, password=None)
    claims = {"jti": str(uuid.uuid4()), "htm": method, "htu": url.split("?")[0].split("#")[0],
              "iat": int(time.time())}
    if token:
        claims["ath"] = b64(hashlib.sha256(token.encode()).digest())
    return jwt.encode(claims, key, algorithm=algorithm(key), headers={"typ": "dpop+jwt", "jwk": public_jwk(key)})


# The harness signs for any method, GET by default, so the listener runs it as its --proof-command.
if __name__ == "__main__":
    url, *token = sys.stdin.read().split()
    method = sys.argv[2] if len(sys.argv) > 2 else "GET"
    with open(sys.argv[1], "rb") as file:
        print(dpop_proof(file.read(), method, url, token[0] if token else None))
