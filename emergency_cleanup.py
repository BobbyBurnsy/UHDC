import os
from google import genai

# Initialize the Gemini client with your FREE API KEY
client = genai.Client(api_key="AIzaSyBmKCMGY9I8Cx0f_BORzvoHweMOv0zatvQ")

print("🚨 INITIALIZING EMERGENCY API CLEANUP 🚨\n")

# --- 1. PURGE ACTIVE CACHES ---
print("Scanning for active Context Caches...")
# ... [rest of your code remains exactly the same] ...
try:
    cache_count = 0
    # Retrieve all active caches in the project
    for cache in client.caches.list():
        print(f"[-] Deleting Cache: {cache.name} (Expires: {cache.expire_time})")
        client.caches.delete(name=cache.name)
        cache_count += 1
    
    if cache_count == 0:
        print("✅ No active caches found.")
    else:
        print(f"✅ Successfully neutralized {cache_count} orphaned caches.")
except Exception as e:
    print(f"❌ Error during cache cleanup: {e}")

print("\n-----------------------------------\n")

# --- 2. PURGE UPLOADED FILES ---
print("Scanning for orphaned files...")
try:
    file_count = 0
    # Retrieve all uploaded files in the project
    for file in client.files.list():
        print(f"[-] Deleting File: {file.name} | Display Name: {file.display_name}")
        client.files.delete(name=file.name)
        file_count += 1

    if file_count == 0:
        print("✅ No lingering files found.")
    else:
        print(f"✅ Successfully wiped {file_count} files from storage.")
except Exception as e:
    print(f"❌ Error during file cleanup: {e}")

print("\n🎉 CLEANUP COMPLETE: Your AI Studio project is a clean slate.")