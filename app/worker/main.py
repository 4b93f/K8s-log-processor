import json
import boto3
import os
from collections import Counter
from io import BytesIO

from PIL import Image
import pytesseract
from prometheus_client import Counter as PCounter, Histogram, start_http_server

MESSAGES_PROCESSED = PCounter("worker_messages_processed_total", "Messages processed successfully")
MESSAGES_FAILED = PCounter("worker_messages_failed_total", "Messages that failed processing")
LINES_PROCESSED = PCounter("worker_lines_processed_total", "Total log lines processed")
HTTP_ERRORS_FOUND = PCounter("worker_http_errors_found_total", "HTTP errors found in logs")
OCR_PROCESSED = PCounter("worker_ocr_processed_total", "Images processed via OCR")
OCR_FAILED = PCounter("worker_ocr_failed_total", "OCR failures")
PROCESSING_DURATION = Histogram("worker_processing_duration_seconds", "Time to process a message")

S3_BUCKET = os.getenv("S3_BUCKET", "log-processing")
SQS_QUEUE_URL = os.getenv("SQS_QUEUE_URL")
AWS_ENDPOINT_URL = os.getenv("AWS_ENDPOINT_URL")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")

IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".tiff", ".bmp", ".gif"}


def get_s3():
    return boto3.client("s3", endpoint_url=AWS_ENDPOINT_URL, region_name=AWS_REGION)

def get_sqs():
    return boto3.client("sqs", endpoint_url=AWS_ENDPOINT_URL, region_name=AWS_REGION)


def is_image(s3_key: str) -> bool:
    ext = os.path.splitext(s3_key)[1].lower()
    return ext in IMAGE_EXTENSIONS


def extract_text_from_image(content: bytes) -> str:
    image = Image.open(BytesIO(content))
    text = pytesseract.image_to_string(image)
    if not text.strip():
        raise ValueError("OCR extracted no text from image")
    return text


def parse_log(content: str) -> dict:
    lines = content.strip().splitlines()
    status_codes = Counter()
    ips = Counter()
    urls = Counter()

    for line in lines:
        parts = line.split()
        if len(parts) < 9:
            continue
        ip = parts[0]
        status = parts[8]
        url = parts[6]
        status_codes[status] += 1
        ips[ip] += 1
        urls[url] += 1

    errors = sum(v for k, v in status_codes.items() if k.startswith(("4", "5")))

    return {
        "total_requests": len(lines),
        "error_count": errors,
        "status_codes": dict(status_codes),
        "top_ips": dict(ips.most_common(5)),
        "top_urls": dict(urls.most_common(5)),
    }


def process_message(message: dict):
    body = json.loads(message["Body"])
    job_id = body["job_id"]
    s3_key = body["s3_key"]

    s3 = get_s3()
    obj = s3.get_object(Bucket=S3_BUCKET, Key=s3_key)
    raw_content = obj["Body"].read()

    with PROCESSING_DURATION.time():
        if is_image(s3_key):
            OCR_PROCESSED.inc()
            text = extract_text_from_image(raw_content)
            result = parse_log(text)
            result["source"] = "ocr"
        else:
            content = raw_content.decode("utf-8")
            result = parse_log(content)
            result["source"] = "text"

    LINES_PROCESSED.inc(result["total_requests"])
    HTTP_ERRORS_FOUND.inc(result["error_count"])

    result["job_id"] = job_id
    result["status"] = "done"

    s3.put_object(
        Bucket=S3_BUCKET,
        Key=f"results/{job_id}/summary.json",
        Body=json.dumps(result),
    )
    print(f"[done] job {job_id} — {result['total_requests']} lines processed (source: {result['source']})")


def main():
    start_http_server(8000)
    print("Metrics server started on port 8000")

    sqs = get_sqs()
    print("Worker started, polling SQS...")

    while True:
        response = sqs.receive_message(
            QueueUrl=SQS_QUEUE_URL,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=10,
        )
        messages = response.get("Messages", [])
        if not messages:
            continue

        message = messages[0]
        try:
            process_message(message)
            MESSAGES_PROCESSED.inc()
            sqs.delete_message(
                QueueUrl=SQS_QUEUE_URL,
                ReceiptHandle=message["ReceiptHandle"],
            )
        except ValueError as e:
            MESSAGES_FAILED.inc()
            OCR_FAILED.inc()
            print(f"[ocr-error] {e}")
        except Exception as e:
            MESSAGES_FAILED.inc()
            print(f"[error] {e}")


if __name__ == "__main__":
    main()
