#!/usr/bin/env python3
"""
Gestion des namespaces Kubernetes via l'API REST NetBackup 11.

Utilisation :
    python nb_namespace_manager.py --list
    python nb_namespace_manager.py --backup <namespace> [--policy <nom_politique>]
    python nb_namespace_manager.py --restore <source_namespace> <dest_namespace> [--image-id <id>]
    
Variables d'environnement requises :
    NB_HOST      : URL du serveur NetBackup (ex: https://netbackup.example.com:1556)
    NB_API_KEY   : Clé API générée depuis l'interface web NetBackup

Option SSL :
    --no-verify  : Désactive la vérification SSL (à utiliser en interne)
"""

import os
import sys
import json
import argparse
import requests
from requests.adapters import HTTPAdapter

# ===================== CONFIGURATION =====================
DEFAULT_POLICY = "Default-Kubernetes-Policy"
DEFAULT_VERIFY_SSL = True

# ===================== GESTION SSL PERSONNALISÉE =====================
class InsecureSSLAdapter(HTTPAdapter):
    """Adaptateur SSL qui ignore la vérification du nom d'hôte."""
    def init_poolmanager(self, *args, **kwargs):
        kwargs['assert_hostname'] = False
        return super().init_poolmanager(*args, **kwargs)

def get_session(verify_ssl=True):
    """Crée une session requests avec gestion SSL adaptée."""
    session = requests.Session()
    if not verify_ssl:
        # Désactive les warnings SSL
        requests.packages.urllib3.disable_warnings()
        # Utilise l'adaptateur personnalisé pour ignorer les erreurs de certificat
        session.mount('https://', InsecureSSLAdapter())
    return session

# ===================== APPELS API =====================
def list_namespaces(session, base_url, api_key):
    """Liste tous les namespaces sauvegardés."""
    url = f"{base_url}/netbackup/workloads/kubernetes/namespaces"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Accept": "application/json"
    }
    try:
        resp = session.get(url, headers=headers)
        resp.raise_for_status()
        data = resp.json()
        print("=== NAMESPACES SAUVEGARDÉS ===")
        print(json.dumps(data, indent=2))
        return data
    except requests.exceptions.RequestException as e:
        print(f"Erreur lors de la liste des namespaces : {e}")
        if hasattr(e, 'response') and e.response:
            print(f"Détail : {e.response.text}")
        sys.exit(1)

def backup_namespace(session, base_url, api_key, namespace, policy_name):
    """Lance une sauvegarde d'un namespace."""
    url = f"{base_url}/netbackup/workloads/kubernetes/namespaces/backup"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "Accept": "application/json"
    }
    payload = {
        "name": namespace,
        "policyName": policy_name
    }
    try:
        resp = session.post(url, headers=headers, json=payload)
        resp.raise_for_status()
        data = resp.json()
        print(f"=== SAUVEGARDE LANCÉE POUR {namespace} ===")
        print(json.dumps(data, indent=2))
        job_id = data.get("jobId")
        if job_id:
            print(f"Job ID : {job_id}")
        return data
    except requests.exceptions.RequestException as e:
        print(f"Erreur lors de la sauvegarde : {e}")
        if hasattr(e, 'response') and e.response:
            print(f"Détail : {e.response.text}")
        sys.exit(1)

def restore_namespace(session, base_url, api_key, source_namespace, dest_namespace, image_id=None):
    """Restaure un namespace vers un autre nom."""
    url = f"{base_url}/netbackup/workloads/kubernetes/namespaces/restore"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "Accept": "application/json"
    }
    payload = {
        "sourceNamespace": source_namespace,
        "destinationNamespace": dest_namespace
    }
    if image_id:
        payload["imageId"] = image_id
    try:
        resp = session.post(url, headers=headers, json=payload)
        resp.raise_for_status()
        data = resp.json()
        print(f"=== RESTAURATION LANCÉE VERS {dest_namespace} ===")
        print(json.dumps(data, indent=2))
        restore_job_id = data.get("restoreJobId")
        if restore_job_id:
            print(f"Job ID : {restore_job_id}")
        return data
    except requests.exceptions.RequestException as e:
        print(f"Erreur lors de la restauration : {e}")
        if hasattr(e, 'response') and e.response:
            print(f"Détail : {e.response.text}")
        sys.exit(1)

# ===================== PARSING ARGUMENTS =====================
def parse_arguments():
    parser = argparse.ArgumentParser(
        description="Gère les namespaces Kubernetes via l'API NetBackup 11."
    )
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--list', action='store_true', help="Lister tous les namespaces sauvegardés")
    group.add_argument('--backup', metavar='NAMESPACE', help="Sauvegarder un namespace")
    group.add_argument('--restore', nargs=2, metavar=('SOURCE', 'DEST'),
                       help="Restaurer un namespace source vers une destination")

    parser.add_argument('--policy', default=DEFAULT_POLICY,
                        help=f"Nom de la politique de sauvegarde (défaut: {DEFAULT_POLICY})")
    parser.add_argument('--image-id', metavar='ID',
                        help="Identifiant de l'image de sauvegarde à restaurer (optionnel)")
    parser.add_argument('--no-verify', action='store_true',
                        help="Désactiver la vérification SSL (certificats auto-signés)")
    
    # Variables d'environnement pour host et clé API
    parser.add_argument('--host', default=os.environ.get('NB_HOST'),
                        help="URL du serveur NetBackup (ex: https://host:1556). Défaut: variable NB_HOST")
    parser.add_argument('--api-key', default=os.environ.get('NB_API_KEY'),
                        help="Clé API NetBackup. Défaut: variable NB_API_KEY")
    
    args = parser.parse_args()
    
    # Vérifications des prérequis
    if not args.host:
        parser.error("L'URL du serveur NetBackup est requise (--host ou variable NB_HOST)")
    if not args.api_key:
        parser.error("La clé API est requise (--api-key ou variable NB_API_KEY)")
    
    # Pour la restauration, l'image-id est optionnel mais on peut ajouter une validation
    if args.restore and args.image_id:
        # just keep it, no additional check needed
        pass
        
    return args

# ===================== MAIN =====================
def main():
    args = parse_arguments()
    
    # Création de la session avec gestion SSL
    session = get_session(verify_ssl=not args.no_verify)
    
    base_url = args.host.rstrip('/')
    api_key = args.api_key
    
    if args.list:
        list_namespaces(session, base_url, api_key)
    elif args.backup:
        backup_namespace(session, base_url, api_key, args.backup, args.policy)
    elif args.restore:
        source, dest = args.restore
        restore_namespace(session, base_url, api_key, source, dest, args.image_id)

if __name__ == "__main__":
    main()
