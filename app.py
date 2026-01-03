from flask import Flask, render_template, request, redirect, url_for, jsonify
import subprocess
import datetime as dt
import os
import logging

DEBUG = os.environ.get("DEBUG", False)
ROOT_PATH = os.environ.get("ROOT_PATH", '/')
SOURCES = os.environ.get("SOURCES", "ADF Front,ADF Back,ADF Duplex").split(",")
MODES = os.environ.get("MODES", "Lineart,Gray,Color").split(",")
RESOLUTIONS = os.environ.get("RESOLUTIONS", "150,300,600").split(",")
DATE_FORMAT = os.environ.get("DATE_FORMAT", "%Y-%m-%d-%H-%M-%S")
PAPERLESS_CONSUME_DIR = os.environ.get("PAPERLESS_CONSUME_DIR", "/mnt/consume")

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

def current_datetime():
    now = dt.datetime.now()
    return now.strftime(DATE_FORMAT)

def get_scanner_info():
    try:
        result = subprocess.run(['scanimage', '-L'], capture_output=True, text=True, timeout=10)
        scanners = []
        for line in result.stdout.split('\n'):
            if 'device' in line and 'scanner' in line:
                scanners.append(line.strip())
        return {'status': 'ok', 'scanners': scanners, 'count': len(scanners)}
    except Exception as e:
        return {'status': 'error', 'message': str(e), 'scanners': [], 'count': 0}

@app.route('/status')
def status():
    scanner_info = get_scanner_info()
    paperless_status = "Connected" if os.path.exists(PAPERLESS_CONSUME_DIR) else "Not available"
    scanner_info['paperless_consume'] = paperless_status
    return jsonify(scanner_info)

def render_root_path(default_date, message=""):
    scanner_info = get_scanner_info()
    scanner_status = f"Scanners found: {scanner_info['count']}" if scanner_info['status'] == 'ok' else "Scanner detection failed"
    paperless_status = "✓ Connected" if os.path.exists(PAPERLESS_CONSUME_DIR) else "✗ Not available"
    
    return render_template('form.html',
        default_date=default_date,
        resolutions=RESOLUTIONS,
        sources=SOURCES,
        modes=MODES,
        message=message,
        scanner_status=scanner_status,
        paperless_status=paperless_status)

@app.route(ROOT_PATH, methods=['GET','POST'])
def root_path():
    default_date = current_datetime()
    try:
        if request.method == 'POST':
            # Extract form data
            name = f"{request.form['date']}-{request.form['name']}"
            mode = request.form['mode']
            resolution = f"{int(request.form['resolution'])}dpi"
            source = request.form['source']
            
            # Paperless integration options
            paperless_tags = request.form.get('tags', '').strip()
            paperless_correspondent = request.form.get('correspondent', '').strip()
            send_to_paperless = request.form.get('send_to_paperless') == 'on'
            
            env_vars = os.environ.copy()
            env_vars["FILENAME"] = name
            env_vars["MODE"] = mode
            env_vars["RESOLUTION"] = resolution
            env_vars["SOURCE"] = source
            env_vars["SEND_TO_PAPERLESS"] = "true" if send_to_paperless else "false"
            env_vars["PAPERLESS_TAGS"] = paperless_tags
            env_vars["PAPERLESS_CORRESPONDENT"] = paperless_correspondent

            logger.info(f"Starting scan job: {name} with {mode} at {resolution}, Paperless: {send_to_paperless}")
            
            subprocess.Popen(['/bin/bash', '/app/scan_adf.sh'], env=env_vars)
            
            message = 'Scan request submitted! '
            if send_to_paperless:
                message += 'Document will be sent to Paperless-ngx after processing.'
            else:
                message += 'Document will be saved locally only.'
                
            return render_root_path(default_date, message=message)
        else:
            return render_root_path(default_date)
    except Exception as e:
        logger.error(f"Error in scan request: {e}")
        if DEBUG:
            raise
        else:
            return render_root_path(default_date, 'There was an error. Check the server logs.')

if __name__ == '__main__':
    app.run(host="0.0.0.0", port=8080, debug=DEBUG)
