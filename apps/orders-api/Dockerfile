FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

# Run as a non-root user; port 8080 does not need privileges.
RUN useradd --uid 10001 --no-create-home appuser
USER 10001

EXPOSE 8080
CMD ["python", "app.py"]
