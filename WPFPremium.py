import os
import hashlib
import streamlit as st
import streamlit.components.v1 as components
from PIL import Image
from pathlib import Path
from google import genai
from google.genai import types

# --- PAGE SETTINGS ---
st.set_page_config(page_title="WPF Console Assistant", page_icon="🖥️", layout="wide")
st.title("🖥️ WPF Console Assistant")
st.caption("Powered by Gemini 3.1 Pro Preview Customtools | Paid Tier | Context Caching Enabled")

# --- CUSTOM CSS FOR MODERN UI ---
st.markdown("""
<style>
    /* Force the copy button to stick to the top as you scroll */
    [data-testid="stCodeBlock"] {
        position: relative;
    }
    [data-testid="stCodeBlock"] button {
        position: sticky !important;
        top: 15px !important;
        z-index: 99 !important;
    }
    
    /* Modern Chatbot App Buttons for the Sidebar */
    [data-testid="stSidebar"] button {
        border-radius: 8px !important;
        border: 1px solid rgba(150, 150, 150, 0.2) !important;
        font-weight: 600 !important;
        transition: all 0.2s ease-in-out !important;
    }
    [data-testid="stSidebar"] button:hover {
        background-color: rgba(100, 150, 255, 0.1) !important;
        border-color: #6c757d !important;
        box-shadow: 0 4px 10px rgba(0,0,0,0.1) !important;
        transform: translateY(-2px);
    }
</style>
""", unsafe_allow_html=True)

def get_file_hash(filepath):
    """Generates a short SHA-256 hash of a file's contents."""
    hasher = hashlib.sha256()
    with open(filepath, 'rb') as f:
        buf = f.read()
        hasher.update(buf)
    return hasher.hexdigest()[:8]

# --- 1. CONFIGURATION ---
TARGET_DIR = r"C:\Users\halol\Desktop\OLD WPF STYLE\DEV"
ALLOWED_EXTENSIONS = {'.ps1', '.psm1', '.xaml', '.xml', '.json', '.md', '.txt'}
IGNORE_DIRS = {'.git', '.vscode', 'node_modules', '__pycache__'}

# Using the universal alias to ensure it always hits the newest stable Flash model
MODEL_NAME = "gemini-3.1-pro-preview-customtools"

# --- 2. BACKGROUND CACHING FUNCTION ---
@st.cache_resource(show_spinner="Scanning and caching your WPF codebase. Check terminal...")
def initialize_gemini():
    # 🚨 ISOLATED API KEY INJECTION 🚨
    # This script will ONLY look for this specific environment variable
    wpf_api_key = os.environ.get("WPF_GEMINI_API_KEY")
    
    if not wpf_api_key:
        st.error("Missing API Key! Please add 'WPF_GEMINI_API_KEY' to your Windows Environment Variables.")
        st.stop()
        
    client = genai.Client(api_key=wpf_api_key)
    base_path = Path(TARGET_DIR)
    files_to_upload = []

    print("\n[WPF ENGINE] Scanning local directory...")
    for file_path in base_path.rglob('*'):
        if file_path.is_file() and file_path.suffix.lower() in ALLOWED_EXTENSIONS:
            if not any(ignored_dir in file_path.parts for ignored_dir in IGNORE_DIRS):
                files_to_upload.append(file_path)

    if not files_to_upload:
        st.error(f"No valid code files found in {TARGET_DIR}.")
        st.stop()

    print(f"[WPF ENGINE] Found {len(files_to_upload)} valid files. Syncing to Cloud...")
    existing_cloud_files = {f.display_name: f for f in client.files.list()}
    uploaded_docs = []

    for i, file_path in enumerate(files_to_upload, 1):
        try:
            file_hash = get_file_hash(file_path)
            unique_display_name = f"{file_path.name}-{file_hash}"

            if unique_display_name in existing_cloud_files:
                print(f"[WPF ENGINE] Skipping {i}/{len(files_to_upload)}: {file_path.name} (Unchanged)")
                uploaded_docs.append(existing_cloud_files[unique_display_name])
            else:
                print(f"[WPF ENGINE] Uploading {i}/{len(files_to_upload)}: {file_path.name} (New/Modified)...")
                doc = client.files.upload(
                    file=str(file_path), 
                    config={'mime_type': 'text/plain', 'display_name': unique_display_name}
                )
                uploaded_docs.append(doc)
        except Exception as e:
            print(f"[WPF ENGINE] WARNING - Failed to process {file_path.name}: {e}")

    print("[WPF ENGINE] Sync complete. Counting tokens...")
    token_response = client.models.count_tokens(model=MODEL_NAME, contents=uploaded_docs)
    exact_token_count = token_response.total_tokens

    # WPF SPECIFIC SYSTEM INSTRUCTIONS
    system_instruction=(
        "You are the lead software engineer for the classic WPF version of the UHDC (Unified Help Desk Console). "
        "Your goal is to maintain, debug, and enhance this PowerShell and WPF architecture. "
        "CRITICAL INSTRUCTIONS: "
        "1. ARCHITECTURE: The GUI layout dictates that the Active Directory search window is prominent on the left, while the Command Center and Help Desk Tools are docked on the right. "
        "2. STYLING: Maintain the custom neon glow color scheme for the XAML buttons. Specifically, use Red for destructive actions and Purple for Master Admin tasks. "
        "3. TERMINOLOGY: The highest tier of our software license is strictly called 'Custom', never 'Platinum'. "
        "4. FILE STRUCTURE: Be aware that NetworkScan.ps1 is NOT located in the tools folder. "
        "5. INCREMENTAL DEVELOPMENT: Treat your previous code suggestions as the new 'Current State' of the project. "
        "6. COMPATIBILITY: Ensure all powershell generation is compatible with powershell 5.1"
        "7. Always reference the provided codebase before answering. Format all PowerShell and XAML output clearly."
    )

    print(f"[WPF ENGINE] Building explicit cache ({exact_token_count:,} tokens)...")
    
    # Create Explicit Cache (4 Hour TTL)
    cache = client.caches.create(
        model=MODEL_NAME,
        config=types.CreateCachedContentConfig(
            contents=uploaded_docs,
            system_instruction=system_instruction,
            ttl="14400s", 
        )
    )
    
    print("[WPF ENGINE] Cache online! Launching UI.\n")
    return client, cache, exact_token_count

# --- INITIALIZATION ---
try:
    gemini_client, codebase_cache, cache_token_count = initialize_gemini()
except Exception as e:
    st.error(f"Failed to connect to Gemini API: {e}")
    st.stop()

if "messages" not in st.session_state:
    st.session_state.messages = []
if "session_tokens" not in st.session_state:
    st.session_state.session_tokens = 0

# PERSISTENT SESSION
if "chat_session" not in st.session_state:
    gemini_history = []
    if st.session_state.messages:
        for msg in st.session_state.messages:
            gemini_history.append(
                types.Content(
                    role=msg["role"],
                    parts=[types.Part.from_text(text=msg["content"])]
                )
            )

    st.session_state.chat_session = gemini_client.chats.create(
        model=MODEL_NAME,
        config=types.GenerateContentConfig(
            cached_content=codebase_cache.name,
            temperature=0.2,
            # 🚨 THIS PART IS CRITICAL FOR THE SLIDER TO WORK 🚨
            thinking_config=types.ThinkingConfig(
                include_thoughts=True,
                thinking_level="MEDIUM" # Initial default
            )
        ),
        history=gemini_history 
    )

# --- 3. SIDEBAR: NATIVE CONTROLS ---
with st.sidebar:
    st.divider()
    st.subheader("🧠 Reasoning Depth")
    
    # Map numerical slider to API keywords
    thinking_map = {1: "LOW", 2: "MEDIUM", 3: "HIGH"}
    
    # FIX: Use a select_slider if you want to use format_func, 
    # OR use a standard slider with a simplified label.
    thinking_val = st.select_slider(
        "Select Complexity", 
        options=[1, 2, 3],
        value=2,
        format_func=lambda x: thinking_map[x],
        help="LOW: Quick tasks. MEDIUM: Daily coding. HIGH: Complex XAML/Logic debugging."
    )
    selected_level = thinking_map[thinking_val]
    
    st.header("⚙️ Workspace Controls")
    
    # Updated Math for PRO Caching Cost ($4.50 per 1M tokens/hour)
    hourly_cost = (cache_token_count / 1_000_000) * 4.50
    
    st.metric(
        label="📦 WPF Cache Size", 
        value=f"{cache_token_count:,} Tokens", 
        delta=f"${hourly_cost:.4f} / hr",
        delta_color="inverse"
    )
    
    st.caption("⏳ Time Remaining on Cache")
    expire_time_iso = codebase_cache.expire_time.isoformat()
    components.html(
        f"""
        <div id="countdown" style="font-family: sans-serif; font-size: 1.2rem; font-weight: 600; color: #ff4b4b;">Loading...</div>
        <script>
            var countDownDate = new Date("{expire_time_iso}").getTime();
            var x = setInterval(function() {{
                var now = new Date().getTime();
                var distance = countDownDate - now;
                
                var hours = Math.floor((distance % (1000 * 60 * 60 * 24)) / (1000 * 60 * 60));
                var minutes = Math.floor((distance % (1000 * 60 * 60)) / (1000 * 60));
                var seconds = Math.floor((distance % (1000 * 60)) / 1000);
                
                document.getElementById("countdown").innerHTML = hours + "h " + minutes + "m " + seconds + "s ";
                
                if (distance < 0) {{
                    clearInterval(x);
                    document.getElementById("countdown").innerHTML = "EXPIRED";
                    document.getElementById("countdown").style.color = "red";
                }}
            }}, 1000);
        </script>
        """,
        height=40
    )
    
    st.divider()
    uploaded_image = st.file_uploader("📸 Attach a Screenshot", type=['png', 'jpg', 'jpeg'])
    st.divider()
    temperature = st.slider("🧠 Creativity (Temperature)", min_value=0.0, max_value=1.0, value=0.2, step=0.1)
    
    # Sync settings to the active session
    st.session_state.chat_session._config.temperature = temperature
    st.session_state.chat_session._config.thinking_config.thinking_level = selected_level
    st.divider()

    # --- BUTTONS: Ensure these are all indented under 'with st.sidebar:' ---
    if st.button("🗑️ Clear Chat History", use_container_width=True):
        st.session_state.messages = []
        st.session_state.session_tokens = 0
        st.session_state.chat_session = gemini_client.chats.create(
            model=MODEL_NAME,
            config=types.GenerateContentConfig(
                cached_content=codebase_cache.name, 
                temperature=temperature,
                thinking_config=types.ThinkingConfig(
                    include_thoughts=True,
                    thinking_level=selected_level
                )
            )
        )
        st.rerun()
        
    # Master Kill Switch
    if st.button("🛑 Stop Billing & Delete Cache", type="primary", use_container_width=True):
        try:
            gemini_client.caches.delete(name=codebase_cache.name)
            st.success("Remote cache deleted! Billing stopped.")
            st.cache_resource.clear()
            if "chat_session" in st.session_state: 
                del st.session_state.chat_session
            st.stop() 
        except Exception as e:
            st.error(f"Could not delete cache: {e}")
        
    if st.button("🔄 Reload Codebase Cache", use_container_width=True):
        try:
            gemini_client.caches.delete(name=codebase_cache.name)
            print(f"[WPF ENGINE] Deleted remote cache: {codebase_cache.name}")
        except Exception as e:
            print(f"[WPF ENGINE] Could not delete remote cache: {e}")
            
        st.cache_resource.clear()
        if "chat_session" in st.session_state: 
            del st.session_state.chat_session
        st.rerun()

    st.divider()
    st.subheader("💾 Export")
    chat_export = "# 🖥️ WPF Console Assistant - Chat Log\n\n"
    for msg in st.session_state.messages:
        role = "🧑‍💻 **You:**" if msg["role"] == "user" else "🤖 **WPF Assistant:**"
        chat_export += f"{role}\n\n{msg['content']}\n\n---\n\n"
    
    st.download_button(
        label="📄 Download Chat as Markdown",
        data=chat_export,
        file_name="WPF_Session_Log.md",
        mime="text/markdown",
        use_container_width=True
    )

# --- 4. DISPLAY CHAT HISTORY ---
col1, col2 = st.columns([8, 2])
with col2:
    st.markdown(f"<div style='text-align: right; color: gray; font-size: 0.9em; padding-bottom: 10px;'>💬 Active Chat Tokens: <strong>{st.session_state.session_tokens:,}</strong></div>", unsafe_allow_html=True)

for msg in st.session_state.messages:
    with st.chat_message(msg["role"]):
        st.markdown(msg["content"])

# --- 5. MAIN CHAT INTERFACE ---
if prompt := st.chat_input("Ask a question about the WPF architecture..."):
    st.session_state.messages.append({"role": "user", "content": prompt})
    with st.chat_message("user"):
        st.markdown(prompt)

    with st.chat_message("assistant"):
        # 1. Prepare placeholders for the "Native App" feel
        thought_placeholder = st.expander("💭 Thought Log", expanded=True)
        thought_text_area = thought_placeholder.empty() # Dynamic area inside expander
        answer_placeholder = st.empty()
        
        full_thought = ""
        full_response = ""

        try:
            # 2. Attach any uploaded images
            if uploaded_image is not None:
                img = Image.open(uploaded_image)
                contents = [prompt, img]
            else:
                contents = prompt

            # 3. Process the stream
            # The customtools model will send 'thought' parts before 'text' parts
            response_stream = st.session_state.chat_session.send_message_stream(contents)
            
            for chunk in response_stream:
                for part in chunk.candidates[0].content.parts:
                    
                    # A. Capture and Display Thoughts
                    if hasattr(part, 'thought') and part.thought:
                        full_thought += part.text
                        thought_text_area.markdown(f"*{full_thought}*") # Italicized thoughts
                    
                    # B. Capture and Display Main Response
                    elif part.text:
                        # Auto-collapse the thought log when the answer starts (Native behavior)
                        # thought_placeholder.update(expanded=False) 
                        
                        full_response += part.text
                        answer_placeholder.markdown(full_response)

            # 4. Save the final response and update token counts
            st.session_state.messages.append({"role": "assistant", "content": full_response})

            # Calculate Active Tokens
            chat_text = "\n".join([m["content"] for m in st.session_state.messages if isinstance(m["content"], str)])
            if chat_text:
                token_resp = gemini_client.models.count_tokens(model=MODEL_NAME, contents=chat_text)
                st.session_state.session_tokens = token_resp.total_tokens
                
            st.rerun()

        except Exception as e:
            st.error(f"API Error: {e}")