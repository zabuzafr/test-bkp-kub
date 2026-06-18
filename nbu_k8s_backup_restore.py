#!/usr/bin/env python3
"""
NetBackup 11.2 - Backup/Restore Kubernetes Namespace via REST API
Fonctions ajoutées : list_backups(), get_last_backup_jobs(), list_namespaces()
Compatible NBU 10.3+ / 11.x avec intégration Kubernetes native (CSI/Operator)
"""

import requests
import json
import time
import logging
import argparse
from datetime import datetime

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s | %(levelname)-8s | %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

class NetBackupK8sClient:
    def __init__(self, master_server: str, port: int = 1556, 
                 username: str = None, password: str = None, 
                 jwt_token: str = None, verify_ssl: bool = True):
        self.base_url = f"https://{master_server}:{port}/netbackup"
        self.session = requests.Session()
        self.session.verify = verify_ssl
        
        if jwt_token:
            self.token = jwt_token
        elif username and password:
            self.token = self._authenticate(username, password)
        else:
            raise ValueError("Fournissez soit un JWT token valide, soit username/password.")

    def _authenticate(self, user: str, pwd: str) -> str:
        logging.info(f"🔑 Authentification auprès de {self.base_url}...")
        resp = self.session.post(f"{self.base_url}/jwt", json={"username": user, "password": pwd})
        resp.raise_for_status()
        token = resp.json().get("token")
        if not token:
            raise RuntimeError("Échec génération JWT. Vérifiez les credentials ou l'activation de nbwebservice.")
        logging.info("✅ JWT obtenu avec succès (expiration: 24h)")
        return token

    def _headers(self) -> dict:
        return {
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json"
        }

    # ==================== NOUVELLES FONCTIONS ====================

    def list_namespaces(self) -> list:
        """Liste les namespaces Kubernetes découverts par NetBackup"""
        logging.info("🌐 Récupération des namespaces découverts...")
        try:
            resp = self.session.get(f"{self.base_url}/kubernetes/namespaces", headers=self._headers())
            resp.raise_for_status()
            ns_list = resp.json().get("namespaces", [])
        except requests.exceptions.HTTPError as e:
            if resp.status_code == 404:
                logging.warning("⚠️ Endpoint /kubernetes/namespaces non disponible. Extraction depuis les images récentes...")
                resp2 = self.session.get(f"{self.base_url}/images", params={"limit": 100}, headers=self._headers())
                resp2.raise_for_status()
                ns_set = {img.get("namespace") for img in resp2.json().get("images", []) if img.get("namespace")}
                ns_list = sorted(list(ns_set))
            else:
                raise
        logging.info(f"✅ {len(ns_list)} namespace(s) trouvé(s)")
        return ns_list

    def list_backups(self, policy_name: str = None, client_name: str = None, namespace: str = None) -> list:
        """Liste les images de backup existantes avec filtres optionnels"""
        params = {}
        if policy_name: params["policyName"] = policy_name
        if client_name: params["clientName"] = client_name
        if namespace: params["namespace"] = namespace

        logging.info(f"📋 Récupération des backups...")
        resp = self.session.get(f"{self.base_url}/images", params=params, headers=self._headers())
        resp.raise_for_status()
        images = resp.json().get("images", [])
        logging.info(f"✅ {len(images)} image(s) trouvée(s)")
        return images

    def get_last_backup_jobs(self, limit: int = 10) -> list:
        """Récupère les N derniers jobs de backup avec statut détaillé"""
        params = {"limit": limit, "sort": "-startTime", "type": "backup"}
        logging.info(f"📊 Récupération des {limit} derniers jobs backup...")
        resp = self.session.get(f"{self.base_url}/jobs", params=params, headers=self._headers())
        resp.raise_for_status()
        jobs = resp.json().get("jobs", [])
        logging.info(f"✅ {len(jobs)} job(s) récupéré(s)")
        return jobs

    # ==================== FONCTIONS EXISTANTES (Backup/Restore) ====================

    def backup_namespace(self, policy_name: str, client_name: str, 
                         namespace: str, backup_type: str = "full") -> dict:
        payload = {
            "policyName": policy_name,
            "clientName": client_name,
            "namespace": namespace,
            "backupType": backup_type
        }
        logging.info(f"🚀 Backup initié: ns={namespace}, policy={policy_name}")
        resp = self.session.post(f"{self.base_url}/kubernetes/backup", json=payload, headers=self._headers())
        resp.raise_for_status()
        result = resp.json()
        job_id = result.get("jobId")
        logging.info(f"✅ Job créé. ID: {job_id}")
        return {"status": "initiated", "jobId": job_id, "details": result}

    def restore_namespace(self, policy_name: str, client_name: str, 
                          backup_id: str, target_namespace: str = None,
                          restore_type: str = "full") -> dict:
        if not target_namespace:
            ts = int(time.time())
            target_namespace = f"{backup_id.split('.')[0]}-restored-{ts}"
            
        payload = {
            "policyName": policy_name,
            "clientName": client_name,
            "backupId": backup_id,
            "namespace": target_namespace,
            "restoreType": restore_type
        }
        logging.info(f"🔄 Restore initié: backup={backup_id} → ns={target_namespace}")
        resp = self.session.post(f"{self.base_url}/kubernetes/restore", json=payload, headers=self._headers())
        resp.raise_for_status()
        result = resp.json()
        job_id = result.get("jobId")
        logging.info(f"✅ Job restore créé. ID: {job_id}")
        return {"status": "initiated", "jobId": job_id, "details": result}

    def get_job_status(self, job_id: str) -> dict:
        resp = self.session.get(f"{self.base_url}/jobs/{job_id}", headers=self._headers())
        resp.raise_for_status()
        return resp.json()

    def wait_for_job_completion(self, job_id: str, timeout_sec: int = 3600) -> dict:
        start = time.time()
        while time.time() - start < timeout_sec:
            status_resp = self.get_job_status(job_id)
            state = status_resp.get("state", "UNKNOWN")
            logging.info(f"⏳ Job {job_id} → État: {state}")
            if state in ("SUCCESS", "FAILURE", "ABORTED"):
                return status_resp
            time.sleep(10)
        raise TimeoutError(f"Job {job_id} n'a pas terminé dans les délais ({timeout_sec}s)")

def main():
    parser = argparse.ArgumentParser(description="NetBackup 11.2 - Gestion Kubernetes via REST API")
    parser.add_argument("--master", required=True, help="IP/FQDN du Master Server NBU")
    parser.add_argument("--port", type=int, default=1556)
    parser.add_argument("--user", help="Utilisateur NBU")
    parser.add_argument("--pass", dest="password", help="Mot de passe NBU")
    parser.add_argument("--jwt", help="Token JWT valide (<24h)")
    parser.add_argument("--verify-ssl", action="store_true", default=True)
    parser.add_argument("--no-verify-ssl", dest="verify_ssl", action="store_false")
    
    # Filtres communs
    parser.add_argument("--policy", help="Nom de la policy NBU Kubernetes")
    parser.add_argument("--client", help="Nom du client NBU (proxy/cluster)")
    
    # Actions
    parser.add_argument("--backup-ns", help="Namespace à sauvegarder")
    parser.add_argument("--restore-ns", help="Namespace cible de restauration")
    parser.add_argument("--backup-id", help="ID d'image NBU à restaurer")
    
    # Nouvelles actions
    parser.add_argument("--list-namespaces", action="store_true", help="Lister les namespaces découverts")
    parser.add_argument("--list-backups", action="store_true", help="Lister les backups existants")
    parser.add_argument("--last-jobs", action="store_true", help="Afficher les 10 derniers jobs backup")
    
    args = parser.parse_args()

    # Validation minimale
    if not (args.user and args.password) and not args.jwt:
        parser.error("Fournissez --user/--pass ou --jwt")

    client = NetBackupK8sClient(
        master_server=args.master, port=args.port,
        username=args.user, password=args.password,
        jwt_token=args.jwt, verify_ssl=args.verify_ssl
    )

    # Exécution des nouvelles fonctions (indépendantes)
    if args.list_namespaces:
        ns = client.list_namespaces()
        print(json.dumps(ns, indent=2))

    if args.list_backups:
        backups = client.list_backups(policy_name=args.policy, client_name=args.client, namespace=args.backup_ns)
        print(json.dumps(backups, indent=2))

    if args.last_jobs:
        jobs = client.get_last_backup_jobs(limit=10)
        print(json.dumps(jobs, indent=2))

    # Backup / Restore (requièrent policy + client)
    if args.backup_ns:
        if not (args.policy and args.client):
            parser.error("--backup-ns nécessite --policy et --client")
        res = client.backup_namespace(args.policy, args.client, args.backup_ns)
        final = client.wait_for_job_completion(res["jobId"])
        logging.info(f"🏁 Backup terminé. État: {final.get('state')}")

    if args.backup_id:
        if not (args.policy and args.client):
            parser.error("--backup-id nécessite --policy et --client")
        res = client.restore_namespace(args.policy, args.client, args.backup_id, target_namespace=args.restore_ns)
        final = client.wait_for_job_completion(res["jobId"])
        logging.info(f"🏁 Restore terminé. État: {final.get('state')}")

if __name__ == "__main__":
    main()
