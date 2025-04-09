FROM python:3.9

WORKDIR /app

COPY templates/ /app/templates/
COPY static/ /app/static/
COPY app.py .

RUN pip install flask

CMD ["python", "app.py"]
