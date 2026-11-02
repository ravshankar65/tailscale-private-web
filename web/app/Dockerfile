FROM python:3.12-slim

# Run as an unprivileged user.
RUN useradd --create-home --uid 10001 app
WORKDIR /srv
COPY app.py .
USER app

ENV PYTHONUNBUFFERED=1
CMD ["python", "app.py"]
