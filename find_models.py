import os
from google import genai

# Pulls your Tier 1 key from Windows
wpf_api_key = os.environ.get("WPF_GEMINI_API_KEY")

if not wpf_api_key:
    print("Error: Could not find WPF_GEMINI_API_KEY environment variable.")
else:
    client = genai.Client(api_key=wpf_api_key)
    print("Here are the exact Flash models your key has access to:")
    
    # Ask the API for the list
    for model in client.models.list():
        if "flash" in model.name:
            print(f"- {model.name}")