#!/usr/bin/env python3
import base64
import http.cookiejar
import json
import os
import pathlib
import time
import urllib.error
import urllib.parse
import urllib.request


def env(name):
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"missing required environment variable {name}")
    return value


def request(
    url,
    method="GET",
    body=None,
    headers=None,
    opener=None,
    expected=(200, 201, 202, 204),
    content_type="application/json",
):
    if body is None:
        payload = None
    elif content_type == "application/x-www-form-urlencoded":
        payload = urllib.parse.urlencode(body, doseq=True).encode()
    else:
        payload = json.dumps(body).encode()
    request_headers = {"Accept": "application/json"}
    if payload is not None:
        request_headers["Content-Type"] = content_type
    request_headers.update(headers or {})
    req = urllib.request.Request(url, data=payload, headers=request_headers, method=method)
    open_request = opener.open if opener else urllib.request.urlopen
    try:
        with open_request(req, timeout=30) as response:
            data = response.read()
            if response.status not in expected:
                raise RuntimeError(f"{method} {url}: unexpected HTTP {response.status}")
            if not data:
                return None
            try:
                return json.loads(data)
            except json.JSONDecodeError:
                return data.decode(errors="replace")
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise RuntimeError(f"{method} {url}: HTTP {error.code}: {detail}") from error


def wait_json(url, headers=None, timeout=600):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            return request(url, headers=headers)
        except Exception as error:
            print(f"waiting for {url}: {error}", flush=True)
            time.sleep(5)
    raise RuntimeError(f"timed out waiting for {url}")


def set_field(fields, names, value):
    names = {name.lower() for name in names}
    for field in fields:
        if str(field.get("name", "")).lower() in names:
            field["value"] = value


def transmission_rpc(method, arguments=None):
    url = "http://transmission:9091/transmission/rpc"
    auth = base64.b64encode(f"admin:{env('ADMIN_PASSWORD')}".encode()).decode()
    payload = json.dumps({"method": method, "arguments": arguments or {}}).encode()
    session_id = None
    for _ in range(2):
        headers = {
            "Accept": "application/json",
            "Authorization": f"Basic {auth}",
            "Content-Type": "application/json",
        }
        if session_id:
            headers["X-Transmission-Session-Id"] = session_id
        req = urllib.request.Request(url, data=payload, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as error:
            if error.code == 409 and error.headers.get("X-Transmission-Session-Id"):
                session_id = error.headers["X-Transmission-Session-Id"]
                continue
            detail = error.read().decode(errors="replace")
            raise RuntimeError(f"Transmission RPC {method}: HTTP {error.code}: {detail}") from error
    raise RuntimeError(f"Transmission RPC {method}: session negotiation failed")


def configure_transmission():
    migration_marker = pathlib.Path("/data/.media-bootstrap/transmission-download-path-v2")
    first_path_migration = not migration_marker.exists()
    transmission_rpc(
        "session-set",
        {
            "cache-size-mb": 16,
            "download-dir": "/data/downloads/complete",
            "download-queue-enabled": True,
            "download-queue-size": 1,
            "incomplete-dir": "/data/downloads/incomplete",
            "incomplete-dir-enabled": True,
            "peer-limit-global": 120,
            "peer-limit-per-torrent": 40,
            "preallocation": 0,
            "queue-stalled-enabled": True,
            "queue-stalled-minutes": 5,
            "speed-limit-down": 8192,
            "speed-limit-down-enabled": True,
        },
    )
    torrents = transmission_rpc(
        "torrent-get",
        {"fields": ["id", "downloadDir", "error", "errorString", "status"]},
    )["arguments"]["torrents"]
    verify_ids = set()
    resume_ids = set()
    for torrent in torrents:
        old_path = torrent.get("downloadDir", "")
        if old_path == "/downloads/complete" or old_path.startswith("/downloads/complete/"):
            new_path = "/data" + old_path
            transmission_rpc(
                "torrent-set-location",
                {"ids": [torrent["id"]], "location": new_path, "move": False},
            )
            verify_ids.add(torrent["id"])
            resume_ids.add(torrent["id"])
        else:
            error = torrent.get("errorString", "")
            if torrent.get("error") == 3 and (
                error.startswith("No data found!") or "Permission denied (13)" in error
            ):
                verify_ids.add(torrent["id"])
                resume_ids.add(torrent["id"])
            elif (
                first_path_migration
                and torrent.get("status") == 0
                and old_path.startswith("/data/downloads/complete")
            ):
                resume_ids.add(torrent["id"])

    if verify_ids:
        transmission_rpc("torrent-verify", {"ids": sorted(verify_ids)})
        time.sleep(1)
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline:
            repairing = transmission_rpc(
                "torrent-get",
                {"ids": sorted(verify_ids), "fields": ["id", "status", "error"]},
            )["arguments"]["torrents"]
            if all(
                torrent["status"] not in (1, 2) and torrent["error"] == 0
                for torrent in repairing
            ):
                break
            time.sleep(2)
        else:
            raise RuntimeError("timed out verifying torrents after download path repair")

    if resume_ids:
        resume_ids = sorted(resume_ids)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            transmission_rpc("torrent-start", {"ids": resume_ids})
            time.sleep(2)
            resumed = transmission_rpc(
                "torrent-get", {"ids": resume_ids, "fields": ["id", "status", "error"]}
            )["arguments"]["torrents"]
            if all(torrent["status"] not in (0, 1, 2) for torrent in resumed):
                break
        else:
            raise RuntimeError("timed out resuming torrents after download path repair")

    if first_path_migration:
        migration_marker.parent.mkdir(parents=True, exist_ok=True)
        migration_marker.write_text("complete\n")


def configure_download_client(name, port, api_version, api_key, category):
    base = f"http://{name}:{port}/api/{api_version}"
    headers = {"X-Api-Key": api_key}
    wait_json(f"{base}/system/status", headers)
    clients = request(f"{base}/downloadclient", headers=headers)
    existing = next((item for item in clients if item.get("implementation") == "Transmission"), None)
    if existing:
        client = existing
    else:
        schemas = request(f"{base}/downloadclient/schema", headers=headers)
        client = next(item for item in schemas if item.get("implementation") == "Transmission")
    client["name"] = "Transmission"
    client["enable"] = True
    client["removeCompletedDownloads"] = True
    client["removeFailedDownloads"] = True
    fields = client.get("fields", [])
    set_field(fields, ["host"], "transmission")
    set_field(fields, ["port"], 9091)
    set_field(fields, ["useSsl"], False)
    set_field(fields, ["urlBase"], "/transmission/")
    set_field(fields, ["username"], "admin")
    set_field(fields, ["password"], env("ADMIN_PASSWORD"))
    set_field(fields, ["movieCategory", "tvCategory", "musicCategory", "category"], category)
    if existing:
        request(f"{base}/downloadclient/{existing['id']}", "PUT", client, headers)
    else:
        request(f"{base}/downloadclient", "POST", client, headers)


def configure_root_folders(name, port, api_version, api_key, paths):
    base = f"http://{name}:{port}/api/{api_version}"
    headers = {"X-Api-Key": api_key}
    existing = {item["path"] for item in request(f"{base}/rootfolder", headers=headers)}
    for path in paths:
        if path not in existing:
            root = {"path": path}
            if name == "lidarr":
                quality_profile = request(f"{base}/qualityprofile", headers=headers)[0]
                metadata_profile = request(f"{base}/metadataprofile", headers=headers)[0]
                root.update(
                    {
                        "name": pathlib.Path(path).name,
                        "defaultQualityProfileId": quality_profile["id"],
                        "defaultMetadataProfileId": metadata_profile["id"],
                        "defaultMonitorOption": "all",
                        "defaultNewItemMonitorOption": "all",
                        "defaultTags": [],
                    }
                )
            request(f"{base}/rootfolder", "POST", root, headers)


def configure_prowlarr_application(name, port, api_key):
    base = "http://prowlarr:9696/api/v1"
    headers = {"X-Api-Key": env("PROWLARR_API_KEY")}
    applications = request(f"{base}/applications", headers=headers)
    existing = next((item for item in applications if item.get("name") == name.title()), None)
    if existing:
        application = existing
    else:
        schemas = request(f"{base}/applications/schema", headers=headers)
        application = next(
            item for item in schemas if str(item.get("implementation", "")).lower() == name.lower()
        )
    application["name"] = name.title()
    application["syncLevel"] = "fullSync"
    fields = application.get("fields", [])
    set_field(fields, ["baseUrl"], f"http://{name}:{port}")
    set_field(fields, ["prowlarrUrl"], "http://prowlarr:9696")
    set_field(fields, ["apiKey"], api_key)
    if existing:
        request(f"{base}/applications/{existing['id']}", "PUT", application, headers)
    else:
        request(f"{base}/applications", "POST", application, headers)


def configure_host_auth(name, port, api_version, api_key_env, password_env):
    base = f"http://{name}:{port}/api/{api_version}"
    headers = {"X-Api-Key": env(api_key_env)}
    host = request(f"{base}/config/host", headers=headers)
    password = env(password_env)
    host.update(
        {
            "authenticationMethod": "forms",
            "authenticationRequired": "enabled",
            "username": "admin",
            "password": password,
            "passwordConfirmation": password,
        }
    )
    request(f"{base}/config/host/{host['id']}", "PUT", host, headers)


def configure_bazarr_auth():
    request(
        "http://bazarr:6767/api/system/settings",
        "POST",
        {
            "settings-auth-type": "form",
            "settings-auth-username": "admin",
            "settings-auth-password": env("ADMIN_PASSWORD"),
        },
        {"X-API-KEY": env("BAZARR_API_KEY")},
        expected=(204,),
        content_type="application/x-www-form-urlencoded",
    )


def jellyfin_login():
    headers = {
        "Authorization": 'MediaBrowser Client="homelab-bootstrap", Device="Kubernetes", DeviceId="media-bootstrap", Version="1"'
    }
    return request(
        "http://jellyfin:8096/Users/AuthenticateByName",
        "POST",
        {"Username": env("JELLYFIN_USERNAME"), "Pw": env("JELLYFIN_PASSWORD")},
        headers,
    )


def ensure_jellyfin_key(access_token):
    headers = {"X-Emby-Token": access_token}
    keys = request("http://jellyfin:8096/Auth/Keys", headers=headers).get("Items", [])
    key = next((item for item in keys if item.get("AppName") == "Janitorr"), None)
    if not key:
        request("http://jellyfin:8096/Auth/Keys?app=Janitorr", "POST", headers=headers)
        keys = request("http://jellyfin:8096/Auth/Keys", headers=headers).get("Items", [])
        key = next(item for item in keys if item.get("AppName") == "Janitorr")
    return key["AccessToken"]


def ensure_jellyfin_libraries(access_token):
    headers = {"X-Emby-Token": access_token}
    existing = {item["Name"] for item in request("http://jellyfin:8096/Library/VirtualFolders", headers=headers)}
    libraries = (
        ("Shows", "tvshows", "/data/TV"),
        ("Anime", "tvshows", "/data/Anime"),
        ("Adult", "movies", "/data/Adult"),
        ("Leaving Soon", "mixed", "/data/Leaving-Soon"),
    )
    for name, collection_type, path in libraries:
        if name in existing:
            continue
        query = urllib.parse.urlencode(
            {"name": name, "collectionType": collection_type, "paths": path, "refreshLibrary": "true"}
        )
        request(f"http://jellyfin:8096/Library/VirtualFolders?{query}", "POST", headers=headers)


def arr_profile_and_root(name, port, api_key, root):
    base = f"http://{name}:{port}/api/v3"
    headers = {"X-Api-Key": api_key}
    profile = request(f"{base}/qualityprofile", headers=headers)[0]
    roots = request(f"{base}/rootfolder", headers=headers)
    folder = next(item for item in roots if item["path"] == root)
    return profile, folder


def configure_jellyseerr():
    wait_json("http://jellyseerr:5055/api/v1/status")
    cookie_jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookie_jar))
    login = {
        "username": env("JELLYFIN_USERNAME"),
        "password": env("JELLYFIN_PASSWORD"),
        "hostname": "jellyfin",
        "port": 8096,
        "urlBase": "",
        "useSsl": False,
        "email": "admin@homelab.local",
        "serverType": 2,
    }
    try:
        request("http://jellyseerr:5055/api/v1/auth/jellyfin", "POST", login, opener=opener)
    except RuntimeError as error:
        if "hostname already configured" not in str(error):
            raise
        login.pop("hostname")
        request("http://jellyseerr:5055/api/v1/auth/jellyfin", "POST", login, opener=opener)

    radarr_profile, radarr_root = arr_profile_and_root("radarr", 7878, env("RADARR_API_KEY"), "/data/Movies")
    sonarr_profile, sonarr_root = arr_profile_and_root("sonarr", 8989, env("SONARR_API_KEY"), "/data/TV")
    existing_radarr = request("http://jellyseerr:5055/api/v1/settings/radarr", opener=opener)
    if not existing_radarr:
        request(
            "http://jellyseerr:5055/api/v1/settings/radarr",
            "POST",
            {
                "name": "Radarr",
                "hostname": "radarr",
                "port": 7878,
                "apiKey": env("RADARR_API_KEY"),
                "useSsl": False,
                "baseUrl": "",
                "activeProfileId": radarr_profile["id"],
                "activeProfileName": radarr_profile["name"],
                "activeDirectory": radarr_root["path"],
                "tags": [],
                "is4k": False,
                "isDefault": True,
                "syncEnabled": True,
                "preventSearch": False,
                "tagRequests": False,
                "overrideRule": [],
                "minimumAvailability": "released",
            },
            opener=opener,
        )
    existing_sonarr = request("http://jellyseerr:5055/api/v1/settings/sonarr", opener=opener)
    if not existing_sonarr:
        request(
            "http://jellyseerr:5055/api/v1/settings/sonarr",
            "POST",
            {
                "name": "Sonarr",
                "hostname": "sonarr",
                "port": 8989,
                "apiKey": env("SONARR_API_KEY"),
                "useSsl": False,
                "baseUrl": "",
                "activeProfileId": sonarr_profile["id"],
                "activeProfileName": sonarr_profile["name"],
                "activeDirectory": sonarr_root["path"],
                "activeAnimeProfileId": sonarr_profile["id"],
                "activeAnimeProfileName": sonarr_profile["name"],
                "activeAnimeDirectory": "/data/Anime",
                "tags": [],
                "animeTags": [],
                "is4k": False,
                "isDefault": True,
                "syncEnabled": True,
                "preventSearch": False,
                "tagRequests": False,
                "overrideRule": [],
                "seriesType": "standard",
                "animeSeriesType": "anime",
                "enableSeasonFolders": True,
                "monitorNewItems": "all",
            },
            opener=opener,
        )
    request("http://jellyseerr:5055/api/v1/settings/initialize", "POST", {}, opener=opener)
    libraries = request("http://jellyseerr:5055/api/v1/settings/jellyfin/library?sync=true", opener=opener)
    enabled = [
        item["id"]
        for item in libraries
        if item.get("name") not in {"Adult", "Leaving Soon"}
        and item.get("type") in {"movie", "movies", "show", "tvshows"}
    ]
    query = urllib.parse.urlencode({"enable": ",".join(enabled)})
    request(f"http://jellyseerr:5055/api/v1/settings/jellyfin/library?{query}", opener=opener)
    request("http://jellyseerr:5055/api/v1/settings/jellyfin/sync", "POST", {"start": True}, opener=opener)


def render_janitorr(jellyfin_api_key):
    template = pathlib.Path("/bootstrap/application.yml").read_text()
    replacements = {
        "__SONARR_API_KEY__": env("SONARR_API_KEY"),
        "__RADARR_API_KEY__": env("RADARR_API_KEY"),
        "__BAZARR_API_KEY__": env("BAZARR_API_KEY"),
        "__JELLYFIN_API_KEY__": jellyfin_api_key,
        "__JELLYFIN_USERNAME__": env("JELLYFIN_USERNAME"),
        "__JELLYFIN_PASSWORD__": env("JELLYFIN_PASSWORD"),
        "__JELLYSEERR_API_KEY__": env("JELLYSEERR_API_KEY"),
    }
    for placeholder, value in replacements.items():
        template = template.replace(placeholder, json.dumps(value))
    destination = pathlib.Path("/janitorr/application.yml")
    temporary = destination.with_suffix(".tmp")
    temporary.write_text(template)
    temporary.chmod(0o640)
    temporary.replace(destination)


def main():
    for path in (
        "/data/downloads/incomplete",
        "/data/downloads/complete/radarr",
        "/data/downloads/complete/sonarr",
        "/data/downloads/complete/lidarr",
        "/data/downloads/complete/whisparr",
        "/data/TV",
        "/data/Anime",
        "/data/Adult",
        "/data/Leaving-Soon",
    ):
        pathlib.Path(path).mkdir(parents=True, exist_ok=True)

    applications = (
        ("radarr", 7878, "v3", env("RADARR_API_KEY"), ["/data/Movies"], "radarr"),
        ("sonarr", 8989, "v3", env("SONARR_API_KEY"), ["/data/TV", "/data/Anime"], "sonarr"),
        ("lidarr", 8686, "v1", env("LIDARR_API_KEY"), ["/data/Music"], "lidarr"),
        ("whisparr", 6969, "v3", env("WHISPARR_API_KEY"), ["/data/Adult"], "whisparr"),
    )
    wait_json("http://prowlarr:9696/api/v1/system/status", {"X-Api-Key": env("PROWLARR_API_KEY")})
    transmission_auth = base64.b64encode(
        f"admin:{env('ADMIN_PASSWORD')}".encode()
    ).decode()
    wait_json(
        "http://transmission:9091/transmission/web/",
        {"Authorization": f"Basic {transmission_auth}"},
    )
    configure_transmission()
    for name, port, api_version, api_key, roots, category in applications:
        configure_download_client(name, port, api_version, api_key, category)
        configure_root_folders(name, port, api_version, api_key, roots)
        configure_prowlarr_application(name, port, api_key)
    configure_host_auth("prowlarr", 9696, "v1", "PROWLARR_API_KEY", "ADMIN_PASSWORD")
    configure_host_auth("radarr", 7878, "v3", "RADARR_API_KEY", "ADMIN_PASSWORD")
    configure_host_auth("sonarr", 8989, "v3", "SONARR_API_KEY", "ADMIN_PASSWORD")
    configure_host_auth("lidarr", 8686, "v1", "LIDARR_API_KEY", "ADMIN_PASSWORD")
    configure_host_auth("whisparr", 6969, "v3", "WHISPARR_API_KEY", "ADMIN_PASSWORD")
    configure_bazarr_auth()

    account = jellyfin_login()
    jellyfin_api_key = ensure_jellyfin_key(account["AccessToken"])
    ensure_jellyfin_libraries(account["AccessToken"])
    configure_jellyseerr()
    render_janitorr(jellyfin_api_key)
    print("media automation bootstrap completed", flush=True)


if __name__ == "__main__":
    main()
