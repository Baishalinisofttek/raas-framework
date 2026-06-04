# Deploy RaaS to PythonAnywhere — Step by Step

No Docker. No credit card. No git needed on PythonAnywhere.

---

## Step 1 — Create Free Account

Go to: https://www.pythonanywhere.com/registration/register/beginner/
- Pick any username (this becomes your URL: yourusername.pythonanywhere.com)
- Free plan is enough

---

## Step 2 — Upload the 5 backend files

1. Click the **Files** tab in PythonAnywhere dashboard
2. Create a new folder called `raas`  (click "New directory")
3. Upload these 5 files from your local `agent/` folder into `/home/yourusername/raas/`:

   - raas_agent.py
   - models.py
   - governance.py
   - mock_data.py
   - requirements_pa.txt   ← use this file (from pythonanywhere/ folder)

---

## Step 3 — Install dependencies

1. Click the **Consoles** tab → Start a new **Bash** console
2. Run:

```bash
cd ~/raas
pip install -r requirements_pa.txt --user
```

Wait for it to finish (~2 minutes).

---

## Step 4 — Create the Web App

1. Click the **Web** tab → **Add a new web app**
2. Click **Next** → Select **Manual configuration** → Select **Python 3.11**
3. Click **Next** → Done

---

## Step 5 — Configure the WSGI file

1. On the Web tab, find **"WSGI configuration file"** — click the link to edit it
2. **Delete everything** in that file
3. Paste this exact content:

```python
import sys
import os

PROJECT_DIR = '/home/YOURUSERNAME/raas'
if PROJECT_DIR not in sys.path:
    sys.path.insert(0, PROJECT_DIR)
os.chdir(PROJECT_DIR)

from raas_agent import app as fastapi_app
from a2wsgi import ASGIMiddleware
application = ASGIMiddleware(fastapi_app)
```

⚠️ Replace YOURUSERNAME with your actual PythonAnywhere username (appears in the file path at top of editor)

4. Click **Save**

---

## Step 6 — Reload the web app

1. Go back to the **Web** tab
2. Click the big green **Reload** button
3. Visit: `https://yourusername.pythonanywhere.com/health`

You should see:
```json
{"status":"healthy","service":"RaaS Agent","version":"1.0.0"...}
```

---

## Step 7 — Update the UI to point to PythonAnywhere

Open `ui/app.js` and change line 4 to:

```js
apiUrl: localStorage.getItem('raas_api_url') || 'https://yourusername.pythonanywhere.com',
```

Then push to GitHub and GitHub Pages will update automatically.

---

## Your live URLs

| What        | URL                                              |
|-------------|--------------------------------------------------|
| API         | https://yourusername.pythonanywhere.com          |
| API Health  | https://yourusername.pythonanywhere.com/health   |
| API Docs    | https://yourusername.pythonanywhere.com/docs     |
| UI          | https://baishalini95.github.io/raas-framework   |

---

## Troubleshooting

If you see a 500 error after reload:
1. Web tab → click **Error log** link
2. Most common issue: wrong username in WSGI path
3. Fix the path and click Reload again
