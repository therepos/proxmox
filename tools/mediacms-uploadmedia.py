import os
import requests

# Configuration
MEDIA_FOLDER = "/mnt/sec/media/videos"  # Mount this inside the container
API_URL = "https://mediacms.threeminuteslab.com/api/v1/media"
AUTH_HEADER = "Basic dG9vcjpLZXl3b3Jkc0BjbVMwMQ=="  # Replace with actual token
CSRF_TOKEN = "JEuG7T53E4nEcbMFlXSUNSwdwpumJCyuhjiet4xuMMfNpkmJSiBkgBTKGOEL6KHS"  # Replace with actual CSRF token

headers = {
    "accept": "application/json",
    "authorization": AUTH_HEADER,
    "X-CSRFTOKEN": CSRF_TOKEN
}

def upload_file(file_path):
    """Uploads a single media file to MediaCMS"""
    file_name = os.path.basename(file_path)
    print(f"Uploading: {file_name}")

    with open(file_path, "rb") as media_file:
        files = {
            "media_file": (file_name, media_file, "video/mp4")  # Adjust MIME type if necessary
        }
        response = requests.post(API_URL, headers=headers, files=files)

    if response.status_code == 201:
        print(f"Success: {file_name} uploaded.")
    else:
        print(f"Failed: {file_name} - {response.status_code} - {response.text}")

def main():
    """Iterates through media folder and uploads files"""
    for file in os.listdir(MEDIA_FOLDER):
        file_path = os.path.join(MEDIA_FOLDER, file)
        if os.path.isfile(file_path) and file.lower().endswith(('.mp4', '.mov', '.mkv')):  # Add more extensions if needed
            upload_file(file_path)

if __name__ == "__main__":
    main()
