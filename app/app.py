from flask import Flask, jsonify
import os

app = Flask(__name__)

ENVIRONMENT = os.getenv("ENVIRONMENT", "local")

@app.route("/")
def home():
  return jsonify({
    "message": "Hello from multu-env-app",
    "environment": ENVIRONMENT
  })

@app.route("/health")
def health():
  return jsonify({
    "status": "healthy",
    "environment": ENVIRONMENT
  }), 200

if __name__ == "__main__":
  app.run(host="0.0.0.0", port=5000)
