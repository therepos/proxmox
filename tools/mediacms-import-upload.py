# purpose: worker script executes the uploading of media files (mov, mp4, mkv) to mediacms
# notes: 
# =====
# update configuration section before use
# authorise access to api at http://yourip:3025/swagger
# customise for local upload:
#   API_URL = "http://yourup:3025/api/v1/media"
#   CSRF_URL = "http://yourup:3025/api/v1/user/token?format=json"
#   response = requests.get(CSRF_URL, headers=headers, verify=False)
#   response = requests.post(API_URL, headers=headers, files=files, data=data, verify=False)

import os
import re
import json
import requests
import base64
import shutil  # For removing folders

# Configuration
MEDIA_FOLDER = "/mnt/sec/media/videos/uploads"
API_BASE_URL = "http://192.168.1.111:3025/api/v1/"
API_MEDIA_URL = API_BASE_URL + "media"
USERNAME = "admin"
PASSWORD = "password"
OUTPUT_FILE = "/mnt/sec/media/videos/uploaded_videos.txt"

# Generate Auth Header
auth_string = f"{USERNAME}:{PASSWORD}"
auth_header = f"Basic {base64.b64encode(auth_string.encode()).decode()}"

headers = {
    "accept": "application/json",
    "authorization": auth_header
}

def generate_title(filename):
    """Cleans and formats the filename as a title."""
    title = os.path.splitext(filename)[0]
    title = re.sub(r'[_\-]+', ' ', title)
    title = re.sub(r'[^a-zA-Z0-9\s]', '', title)
    return title.strip().title()

def ensure_playlist_exists(playlist_name):
    """Ensures a playlist exists in MediaCMS before uploading videos."""
    playlist_api_url = API_BASE_URL + "playlists/"
    response = requests.get(playlist_api_url, headers=headers, verify=False)

    if response.status_code == 200:
        try:
            existing_playlists = response.json()
            if isinstance(existing_playlists, dict) and "results" in existing_playlists:
                existing_playlists = existing_playlists["results"]  # Handle paginated responses
            elif not isinstance(existing_playlists, list):
                print(f"❌ Unexpected API response format: {existing_playlists}")
                return None

            for playlist in existing_playlists:
                if isinstance(playlist, dict) and "title" in playlist:
                    if playlist["title"].strip() == playlist_name.strip():
                        print(f"✅ Playlist '{playlist_name}' already exists.")
                        return playlist["api_url"]  # Return API URL of the playlist
        except json.JSONDecodeError:
            print(f"❌ Failed to parse JSON response: {response.text}")
            return None

    print(f"Creating new playlist: {playlist_name}...")
    data = {
        "title": playlist_name,
        "description": f"Auto-created playlist for {playlist_name}"
    }
    response = requests.post(playlist_api_url, headers=headers, json=data, verify=False)

    if response.status_code == 201:
        playlist_api_url = response.json().get("api_url")
        print(f"✅ Playlist '{playlist_name}' created successfully.")
        return playlist_api_url
    else:
        print(f"❌ Failed to create playlist '{playlist_name}': {response.text}")
        return None

def upload_file(file_path, playlist_name):
    """Uploads a media file via API and deletes it after a successful upload."""
    file_name = os.path.basename(file_path)
    title = generate_title(file_name)

    print(f"Uploading: {file_name} with title: {title}")

    with open(file_path, "rb") as media_file:
        files = {
            "media_file": (file_name, media_file, "video/mp4")
        }
        data = {
            "title": title,
            "description": f"Uploaded video: {title}"
        }
        response = requests.post(API_MEDIA_URL, headers=headers, files=files, data=data, verify=False)

    if response.status_code == 201:
        media_token = response.json().get("friendly_token")
        print(f"✅ Success: {file_name} uploaded with media token {media_token}.")

        with open(OUTPUT_FILE, "a") as f:
            f.write(f"{playlist_name},{media_token}\n")

        print(f"✅ Upload successful. Checking file for deletion: {file_path}")

        if os.path.exists(file_path):
            try:
                os.remove(file_path)
                print(f"✅ Deleted: {file_path}")
            except Exception as e:
                print(f"❌ Error deleting {file_path}: {e}")
        else:
            print(f"⚠️ Warning: File {file_path} does not exist, cannot delete.")

        return media_token
    else:
        print(f"❌ Failed: {file_name} - {response.status_code} - {response.text}")
        return None

def process_directory():
    """Uploads videos, ensures playlists exist, and removes files after upload."""
    if os.path.exists(OUTPUT_FILE):
        os.remove(OUTPUT_FILE)  

    for folder in os.listdir(MEDIA_FOLDER):
        folder_path = os.path.join(MEDIA_FOLDER, folder)

        if os.path.isdir(folder_path):
            playlist_name = folder
            print(f"📂 Processing folder '{playlist_name}'...")

            ensure_playlist_exists(playlist_name)

            video_files = [f for f in os.listdir(folder_path) if f.lower().endswith(('.mp4', '.mov', '.mkv'))]
            for video in video_files:
                video_path = os.path.join(folder_path, video)
                upload_file(video_path, playlist_name)

            try:
                shutil.rmtree(folder_path)
                print(f"✅ Removed folder: {folder_path}")
            except Exception as e:
                print(f"❌ Error removing folder {folder_path}: {e}")

    print(f"✅ All videos uploaded. Stored friendly tokens in {OUTPUT_FILE}.")

if __name__ == "__main__":
    process_directory()
