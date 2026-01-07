
from datetime import datetime
from flask import Flask, render_template

app = Flask(__name__)

@app.route('/')
def home():
    return render_template('index.html', current_year=datetime.now().year)

@app.route('/about')
def about():
    return render_template('about.html', current_year=datetime.now().year)

@app.route('/contact', methods=['GET', 'POST'])
def contact():
    if request.method == 'POST':
        # For now, just echo back the submitted data
        name = request.form.get('name')
        message = request.form.get('message')
        return f"Thanks {name}, we received your message: {message}"
    return render_template('contact.html', current_year=datetime.now().year)

@app.route('/health')
def health():
    return "OK", 200

# Local testing convenience (container runs via Gunicorn)
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
