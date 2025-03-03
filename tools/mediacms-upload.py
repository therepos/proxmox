import os
import re
import json
import requests
import base64

MEDIA_FOLDER = "/mnt/sec/media/temp"
API_BASE_URL = "http://192.168.1.111:3025/api/v1/"
API_MEDIA_URL = API_BASE_URL + "media"
USERNAME = "toor"
PASSWORD = "Keywords@cmS01"
OUTPUT_FILE = "/mnt/sec/media/temp/uploaded_videos.txt"

auth_string = f"{USERNAME}:{PASSWORD}"
auth_header = f"Basic {base64.b64encode(auth_string.encode()).decode()}"

headers = {
    "accept": "application/json",
    "authorization": auth_header
}

def generate_title(filename):
    title = os.path.splitext(filename)[0]
    title = re.sub(r'[_\-]+', ' ', title)
    title = re.sub(r'[^a-zA-Z0-9\s]', '', title)
    return title.strip().title()

def upload_file(file_path, playlist_name):
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
        print(f"Success: {file_name} uploaded with media token {media_token}.")

        with open(OUTPUT_FILE, "a") as f:
            f.write(f"{playlist_name},{media_token}\n")

        return media_token
    else:
        print(f"Failed: {file_name} - {response.status_code} - {response.text}")
        return None

def process_directory():
    if os.path.exists(OUTPUT_FILE):
        os.remove(OUTPUT_FILE)

    for folder in os.listdir(MEDIA_FOLDER):
        folder_path = os.path.join(MEDIA_FOLDER, folder)

        if os.path.isdir(folder_path):
            playlist_name = folder
            print(f"Processing folder '{playlist_name}'...")

            # Ensure the playlist exists before uploading videos
            ensure_playlist_exists(playlist_name)

            video_files = [f for f in os.listdir(folder_path) if f.lower().endswith(('.mp4', '.mov', '.mkv'))]
            for video in video_files:
                video_path = os.path.join(folder_path, video)
                upload_file(video_path, playlist_name)

                # ✅ Delete the video file after uploading
                try:
                    os.remove(video_path)
                    print(f"Deleted: {video_path}")
                except Exception as e:
                    print(f"Error deleting {video_path}: {e}")

            # ✅ Remove the folder if it is empty
            try:
                if not os.listdir(folder_path):  # Check if folder is empty
                    os.rmdir(folder_path)
                    print(f"Removed empty folder: {folder_path}")
            except Exception as e:
                print(f"Error removing folder {folder_path}: {e}")

    print(f"All videos uploaded. Stored friendly tokens in {OUTPUT_FILE}.")

if __name__ == "__main__":
    process_directory()
