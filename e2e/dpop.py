# Prints a DPoP proof (RFC 9449) for one request: python3 dpop.py <key.pem>,
# with the URL on the first line of stdin and the access token on the second.
import base64, hashlib, sys, time, uuid
import jwt
from cryptography.hazmat.primitives.serialization import load_pem_private_key


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def octets(number):
    return number.to_bytes((number.bit_length() + 7) // 8, "big")


def dpop_proof(key_pem, method, url, token):
    key = load_pem_private_key(key_pem, password=None)
    nums = key.public_key().public_numbers()
    jwk = {"kty": "RSA", "e": b64(octets(nums.e)), "n": b64(octets(nums.n))}
    claims = {"jti": str(uuid.uuid4()), "htm": method, "htu": url.split("?")[0].split("#")[0],
              "iat": int(time.time()), "ath": b64(hashlib.sha256(token.encode()).digest())}
    return jwt.encode(claims, key, algorithm="RS256", headers={"typ": "dpop+jwt", "jwk": jwk})


# The harness signs for any method: python3 dpop.py <key.pem> [METHOD], GET by
# default, so the listener runs it as its --proof-command.
if __name__ == "__main__":
    url, token = sys.stdin.read().split()
    method = sys.argv[2] if len(sys.argv) > 2 else "GET"
    with open(sys.argv[1], "rb") as file:
        print(dpop_proof(file.read(), method, url, token))
