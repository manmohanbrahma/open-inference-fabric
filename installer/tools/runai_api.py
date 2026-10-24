#!/usr/bin/env python3
"""Small Run:ai REST client for oif (standard library only).

Credentials come from the environment (RUNAI_URL, RUNAI_USER, RUNAI_PASSWORD, RUNAI_CA); tokens and passwords are
never printed. Commands:
  check                                  log in and print the clusters
  project NAME GPU_DESERVED GPU_LIMIT    create the project if missing (GPU_LIMIT -1 = no limit), print its namespace
  admin EMAIL                            make EMAIL a System administrator with the password in RUNAI_NEW_PASSWORD
  template FILE                          create or update the workload template in FILE (JSON)
  submit KIND NAME PROJECT TEMPLATE [COMMAND [ARGS]]  submit a training or workspace (KIND trainings, workspaces) from a template
"""
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.request

URL = os.environ["RUNAI_URL"].rstrip("/")
CTX = ssl.create_default_context(cafile=os.environ.get("RUNAI_CA") or None)


def call(method: str, path: str, body: dict | None = None, token: str | None = None) -> tuple[int, object]:
    req = urllib.request.Request(URL + path, method=method, data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw.decode(errors="replace")[:300]


def login() -> str:
    base = {"grantType": "password", "username": os.environ["RUNAI_USER"], "password": os.environ["RUNAI_PASSWORD"]}
    tried = []
    for extra in ({}, {"clientID": "runai"}, {"clientID": "cli"}):
        status, out = call("POST", "/api/v1/token", {**base, **extra})
        if status == 200 and isinstance(out, dict) and out.get("accessToken"):
            return out["accessToken"]
        tried.append(f"{extra or 'no clientID'}: HTTP {status}")
    sys.exit("login failed (" + "; ".join(tried) + ")")


def clusters(token: str) -> list:
    status, out = call("GET", "/api/v1/clusters", token=token)
    if status != 200:
        sys.exit(f"GET /api/v1/clusters: HTTP {status} {out}")
    return out


def node_pool(token: str, cluster: str, name: str) -> dict:
    """The node pool's id and name (projects reference node pools by id)."""
    for path in (f"/api/v1/node-pools?filterBy=clusterId=={cluster}", "/api/v1/node-pools"):
        status, out = call("GET", path, token=token)
        if status == 200:
            pools = out
            if isinstance(out, dict):   # the list sits under a key ("nodepools", "nodePools", ...): take the list of objects
                pools = next((v for v in out.values() if isinstance(v, list) and v and isinstance(v[0], dict)), [])
                if not pools:
                    print(f"node pools: no list in response keys {sorted(out)}", file=sys.stderr)
            for p in pools or []:
                if p.get("name") == name and (not p.get("clusterId") or p.get("clusterId") == cluster):
                    return {"id": str(p["id"]), "name": p["name"]}
    sys.exit(f"node pool {name} not found (GET /api/v1/node-pools: HTTP {status})")


def project(token: str, name: str, deserved: float, limit: float) -> None:
    status, out = call("GET", "/api/v1/org-unit/projects", token=token)
    if status != 200:
        sys.exit(f"GET projects: HTTP {status} {out}")
    found = [p for p in out.get("projects", []) if p.get("name") == name]
    if not found:
        cl = clusters(token)
        if not cl:
            sys.exit("no Run:ai cluster registered")
        # with Run:ai's over-quota feature off (the default) the quota is a hard limit and the API rejects
        # over-quota weights; a limit is only sent when it differs from the quota
        gpu = {"deserved": deserved}
        if 0 <= limit != deserved:
            gpu["limit"] = limit
        pool = node_pool(token, cl[0]["uuid"], "default")
        body = {"name": name, "clusterId": cl[0]["uuid"], "resources": [{"nodePool": {"id": pool["id"], "name": pool["name"]}, "gpu": gpu}]}
        status, out = call("POST", "/api/v1/org-unit/projects", body, token)
        if status not in (200, 201, 202):
            sys.exit(f"create project {name}: HTTP {status} {out}")
        found = [out]
    for _ in range(60):   # the namespace appears once the cluster has synced the project
        status, out = call("GET", "/api/v1/org-unit/projects", token=token)
        p = next((x for x in out.get("projects", []) if x.get("name") == name), {})
        ns = (p.get("status") or {}).get("namespace")
        if ns:
            print(ns)
            return
        time.sleep(5)
    sys.exit(f"project {name} has no namespace after 5 min")


def try_login(user: str, password: str) -> str | None:
    status, out = call("POST", "/api/v1/token", {"grantType": "password", "username": user, "password": password})
    return out["accessToken"] if status == 200 and isinstance(out, dict) and out.get("accessToken") else None


def admin(token: str, email: str) -> None:
    """Make EMAIL a local System administrator of the whole tenant with the password in RUNAI_NEW_PASSWORD."""
    new = os.environ["RUNAI_NEW_PASSWORD"]
    status, users = call("GET", "/api/v1/users", token=token)
    if status != 200:
        sys.exit(f"GET users: HTTP {status} {users}")
    user = next((u for u in users if u.get("username", "").lower() == email.lower()), None)
    temp = None
    if user is None:
        status, out = call("POST", "/api/v1/users", {"email": email, "resetPassword": False}, token)
        if status not in (200, 201):
            sys.exit(f"create user {email}: HTTP {status} {out}")
        user, temp = {"id": out["id"]}, out["tempPassword"]
        print(f"user {email} created")
    # the System administrator role, at the scope of the tenant the generated administrator holds it on
    status, out = call("GET", "/api/v1/authorization/access-rules", token=token)
    if status != 200:
        sys.exit(f"GET access rules: HTTP {status} {out}")
    rules = out.get("accessRules", [])
    sysadmin = next((r for r in rules if r.get("roleName") == "System administrator" and r.get("scopeType") == "tenant"), None)
    if sysadmin is None:
        sys.exit("no System administrator access rule on the tenant to copy")
    if not any(r.get("subjectId", "").lower() == email.lower() and r.get("roleId") == sysadmin["roleId"]
               and r.get("scopeType") == "tenant" for r in rules):
        body = {"subjectId": email, "subjectType": "user", "roleId": sysadmin["roleId"],
                "scopeId": sysadmin["scopeId"], "scopeType": "tenant"}
        status, out = call("POST", "/api/v1/authorization/access-rules", body, token)
        if status not in (200, 201):
            sys.exit(f"access rule for {email}: HTTP {status} {out}")
        print(f"{email}: System administrator on tenant {sysadmin.get('scopeName', sysadmin['scopeId'])}")
    if try_login(email, new):
        print(f"{email} logs in with the configured password")
        return
    if temp is None:   # existing user with another password: issue a temporary one, then set ours
        status, out = call("POST", f"/api/v1/users/{user['id']}/password", {}, token)
        if status != 200 or not isinstance(out, dict) or not out.get("tempPassword"):
            sys.exit(f"reset password of {email}: HTTP {status}")
        temp = out["tempPassword"]
    user_token = try_login(email, temp)
    if not user_token:
        sys.exit(f"{email} cannot log in with its temporary password")
    status, out = call("POST", "/api/v1/me/password", {"currentPassword": temp, "newPassword": new}, user_token)
    if status not in (200, 204):
        sys.exit(f"set password of {email}: HTTP {status} {out} (Run:ai's password policy: upper and lower case, a digit, a symbol)")
    for _ in range(12):   # the identity service may take a moment to accept the new password
        if try_login(email, new):
            print(f"{email} logs in with the configured password")
            return
        time.sleep(5)
    sys.exit(f"{email} does not log in with the configured password")


def template(token: str, path: str) -> None:
    """Create or update a workload template from a JSON file {"kind": "trainings"|"workspaces", "meta": ..., "spec": ...}."""
    with open(path, encoding="utf-8") as f:
        t = json.load(f)
    kind, name = t.pop("kind"), t["meta"]["name"]
    status, out = call("GET", "/api/v1/workload-templates", token=token)
    if status != 200:
        sys.exit(f"GET templates: HTTP {status} {out}")
    found = next((e for e in out.get("entries", []) if e["meta"]["name"] == name), None)
    if found:
        status, out = call("PUT", f"/api/v1/workload-templates/{kind}/{found['meta']['id']}", t, token)
        verb = "updated"
    else:
        status, out = call("POST", f"/api/v1/workload-templates/{kind}", t, token)
        verb = "created"
    if status not in (200, 201, 202):
        sys.exit(f"template {name}: HTTP {status} {out}")
    print(f"template {name} {verb}")


def submit(token: str, kind: str, name: str, project_name: str, template_name: str, command: str = "", args: str = "") -> None:
    """Submit a workload (kind: trainings or workspaces) from a template, optionally with another command."""
    status, out = call("GET", "/api/v1/org-unit/projects", token=token)
    proj = next((p for p in out.get("projects", []) if p.get("name") == project_name), None) if status == 200 else None
    if not proj:
        sys.exit(f"project {project_name} not found")
    status, out = call("GET", "/api/v1/workload-templates", token=token)
    tmpl = next((e for e in out.get("entries", []) if e["meta"]["name"] == template_name), None) if status == 200 else None
    if not tmpl:
        sys.exit(f"template {template_name} not found")
    body = {"name": name, "projectId": str(proj["id"]), "clusterId": proj["clusterId"], "templateId": tmpl["meta"]["id"], "spec": {}}
    if command:
        body["spec"]["command"] = command
    if args:
        body["spec"]["args"] = args
    status, out = call("POST", f"/api/v1/workloads/{kind}", body, token)
    if status not in (200, 201, 202):
        sys.exit(f"submit {name}: HTTP {status} {out}")
    print(f"{kind[:-1]} {name} submitted in project {project_name} from template {template_name}")


def main() -> None:
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    token = login()
    if cmd == "check":
        for c in clusters(token):
            print(c.get("name"), c.get("uuid"), c.get("version", ""), c.get("lastLiveness", ""))
    elif cmd == "project" and len(sys.argv) == 5:
        project(token, sys.argv[2], float(sys.argv[3]), float(sys.argv[4]))
    elif cmd == "admin" and len(sys.argv) == 3:
        admin(token, sys.argv[2])
    elif cmd == "template" and len(sys.argv) == 3:
        template(token, sys.argv[2])
    elif cmd == "submit" and 6 <= len(sys.argv) <= 8:
        submit(token, *sys.argv[2:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
