import os

from flask import Flask, render_template

app = Flask(__name__)


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/healthz")
def healthz():
    return {"status": "ok"}


if __name__ == "__main__":
    # OpenShift runs containers as a random non-root UID, which cannot bind
    # to ports below 1024, so listen on 8080 by default.
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
