import os
import re
import requests
import base64

# Configuration
MEDIA_FOLDER = "/mnt/sec/media/temp"  # Folder to scan for new media files
API_URL = "https://mediacms.threeminuteslab.com/api/v1/media"
CSRF_URL = "https://mediacms.threeminuteslab.com/api/v1/user/token?format=json"
USERNAME = "admin"  # Replace with actual username
PASSWORD = "password"  # Replace with actual password

# Generate Auth Header
auth_string = f"{USERNAME}:{PASSWORD}"
auth_header = f"Basic {base64.b64encode(auth_string.encode()).decode()}"

headers = {
    "accept": "application/json",
    "authorization": auth_header
}

def get_csrf_token():
    """Fetches a new CSRF token from the API"""
    response = requests.get(CSRF_URL, headers=headers)
    if response.status_code == 200:
        return response.json().get("token")
    print(f"Failed to get CSRF Token: {response.text}")
    return None

def generate_title(filename):
    """Generates a title from the filename by removing extensions and special characters"""
    title = os.path.splitext(filename)[0]  # Remove extension
    title = re.sub(r'[_\-]+', ' ', title)  # Replace underscores and dashes with spaces
    title = re.sub(r'[^a-zA-Z0-9\s]', '', title)  # Remove special characters
    return title.strip().title()  # Capitalize title

def delete_uploaded_file(file_path):
    """Deletes the uploaded file from the source folder"""
    try:
        os.remove(file_path)
        print(f"Deleted {file_path} after successful upload.")
    except Exception as e:
        print(f"Error deleting {file_path}: {e}")

def upload_file(file_path, csrf_token):
    """Uploads a single media file to MediaCMS"""
    file_name = os.path.basename(file_path)
    title = generate_title(file_name)
    description = f"Uploaded video: {title}"  # Optional description format

    print(f"Uploading: {file_name} with title: {title}")

    with open(file_path, "rb") as media_file:
        files = {
            "media_file": (file_name, media_file, "video/mp4")
        }
        data = {
            "title": title,
            "description": description
        }
        headers["X-CSRFTOKEN"] = csrf_token
        response = requests.post(API_URL, headers=headers, files=files, data=data)

    if response.status_code == 201:
        print(f"Success: {file_name} uploaded as '{title}'.")
        delete_uploaded_file(file_path)  # Delete file after successful upload
    else:
        print(f"Failed: {file_name} - {response.status_code} - {response.text}")

def main():
    """Iterates through media folder, uploads new files, and deletes them after upload"""
    csrf_token = get_csrf_token()
    if not csrf_token:
        print("No CSRF token, exiting.")
        return

    for file in os.listdir(MEDIA_FOLDER):
        file_path = os.path.join(MEDIA_FOLDER, file)
        if os.path.isfile(file_path) and file.lower().endswith(('.mp4', '.mov', '.mkv')):
            upload_file(file_path, csrf_token)

if __name__ == "__main__":
    main()
