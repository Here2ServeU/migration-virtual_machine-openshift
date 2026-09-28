FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY templates/ /app/templates/
COPY static/ /app/static/
COPY app.py .

# OpenShift assigns a random UID that belongs to group 0, so make the app
# files group-readable by root and never run as root ourselves.
RUN chgrp -R 0 /app && chmod -R g=u /app
USER 1001

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
