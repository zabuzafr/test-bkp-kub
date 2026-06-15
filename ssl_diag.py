#!/usr/bin/env python3
import ssl
import socket
import certifi
import requests
from urllib3.exceptions import InsecureRequestWarning

# --- 1. Info Environnement ---
print(f"Python version: {ssl.OPENSSL_VERSION}")
print(f"Certifi store: {certifi.where()}")

# --- 2. Test cURL Simulé ---
host = "votre_serveur_netbackup"
port = 1556
try:
    cert_pem = ssl.get_server_certificate((host, port), ssl_version=ssl.PROTOCOL_TLS_CLIENT)
    print(f"\nCertificat brut (début):\n{cert_pem[:200]}...")
except Exception as e:
    print(f"Erreur brute: {e}")

# --- 3. Test avec 'REQUESTS_CA_BUNDLE' ---
custom_ca = "/chemin/vers/votre/certificat.pem"  # SPÉCIFIEZ ICI
try:
    requests.get(f"https://{host}:{port}", verify=custom_ca, timeout=5)
    print("\n✓ Validation avec CA personnalisé : RÉUSSIE")
except requests.exceptions.SSLError as e:
    print(f"\n✗ Validation avec CA personnalisé : {e}")

# --- 4. Test sans vérif SSL ---
requests.packages.urllib3.disable_warnings(InsecureRequestWarning)
try:
    requests.get(f"https://{host}:{port}", verify=False, timeout=5)
    print("\n✓ Connexion non vérifiée : OK")
except Exception as e:
    print(f"\n✗ Connexion non vérifiée : {e}")

# --- 5. Analyse complète avec OpenSSL (via python ssl) ---
ctx = ssl.create_default_context()
try:
    with socket.create_connection((host, port), timeout=5) as sock:
        with ctx.wrap_socket(sock, server_hostname=host) as ssock:
            cert = ssock.getpeercert()
    print("\n✓ Socket SSL direct : RÉUSSIE")
    print(f"  Sujet: {cert.get('subject', 'N/A')}")
    print(f"  SAN: {cert.get('subjectAltName', 'N/A')}")
    print(f"  Émetteur: {cert.get('issuer', 'N/A')}")
except Exception as e:
    print(f"\n✗ Socket SSL direct : {e}")
