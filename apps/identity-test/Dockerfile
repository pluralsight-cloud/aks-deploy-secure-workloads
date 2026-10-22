FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY identity_check.py .

# Run as a non-root user.
RUN useradd --uid 10001 --no-create-home appuser
USER 10001

CMD ["python", "identity_check.py"]
