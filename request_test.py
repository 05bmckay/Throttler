# Filename: hubspot_load_tester.py

import requests
import hashlib
import hmac
import time
import json
import argparse
import os
import random
import string
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from urllib.parse import urlparse
import statistics

# --- Configuration ---
SIGNATURE_VERSION = "v2"  # Use v2 signature
REQUEST_TIMEOUT_SECONDS = 10 # Timeout for individual requests

# --- Helper Functions ---

def generate_random_string(length=10):
    """Generates a random alphanumeric string."""
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=length))

def generate_payload():
    """Generates a sample HubSpot action payload."""
    # Customize this as needed to match expected data structures
    return {
        "portalId": random.randint(100000, 999999),
        "actionId": generate_random_string(8),
        "callbackId": f"callback-{generate_random_string(12)}",
        "payload": {
            "contact_vid": random.randint(1000, 50000),
            "some_property": f"value_{generate_random_string(5)}",
            "another_setting": random.choice([True, False]),
            "list_items": [random.randint(1, 100) for _ in range(random.randint(1, 5))]
        }
        # Add other fields based on your action_controller expectations if needed
        # "data": {...} # Alternate payload structure
    }

def calculate_signature(secret, method, uri, body, timestamp):
    """Calculates the HubSpot request signature (only v2 implemented here)."""
    if SIGNATURE_VERSION == "v1":
        # v1: sha256(client_secret + request_body)
        source_string = secret + body
        return hashlib.sha256(source_string.encode('utf-8')).hexdigest()
    elif SIGNATURE_VERSION == "v2":
        # v2: hex(hmac_sha256(client_secret, method + uri + request_body + timestamp))
        source_string = method + uri + body + str(timestamp)
        return hmac.new(
            secret.encode('utf-8'),
            source_string.encode('utf-8'),
            digestmod=hashlib.sha256
        ).hexdigest()
    else:
        raise ValueError(f"Unsupported signature version: {SIGNATURE_VERSION}")

def send_request(session, base_url, endpoint_path, secret):
    """Generates payload, calculates signature, and sends a single POST request."""
    start_time = time.monotonic()
    status_code = None
    error = None

    try:
        method = "POST"
        payload = generate_payload()
        request_body = json.dumps(payload, separators=(',', ':')) # Compact JSON
        # Ensure URL for signature includes the path
        parsed_base_url = urlparse(base_url)
        # Reconstruct base ensuring no trailing slash for path joining
        clean_base_url = f"{parsed_base_url.scheme}://{parsed_base_url.netloc}"
        full_url = f"{clean_base_url}{endpoint_path}"
        # URI for signature requires the path
        uri = full_url

        # Current time in milliseconds
        timestamp = int(time.time() * 1000)

        signature = calculate_signature(secret, method, uri, request_body, timestamp)

        headers = {
            "Content-Type": "application/json",
            f"X-HubSpot-Signature-Version": SIGNATURE_VERSION,
            f"X-HubSpot-Signature": signature,
            f"X-HubSpot-Request-Timestamp": str(timestamp),
            # Add other headers if needed
        }

        response = session.post(
            full_url,
            data=request_body.encode('utf-8'),
            headers=headers,
            timeout=REQUEST_TIMEOUT_SECONDS
        )
        status_code = response.status_code

    except requests.exceptions.Timeout:
        error = "Timeout"
    except requests.exceptions.ConnectionError:
        error = "ConnectionError"
    except requests.exceptions.RequestException as e:
        error = f"RequestException: {e}"
    except Exception as e:
        error = f"OtherException: {e}"

    end_time = time.monotonic()
    latency = end_time - start_time
    return status_code, latency, error


# --- Main Execution ---
def main():
    parser = argparse.ArgumentParser(description="HubSpot Webhook Load Tester")
    parser.add_argument("url", help="Base URL of the target server (e.g., http://localhost:4000)")
    parser.add_argument("-r", "--rps", type=int, required=True, help="Target requests per second")
    parser.add_argument("-d", "--duration", type=int, required=True, help="Test duration in seconds")
    parser.add_argument("-s", "--secret", help="HubSpot Client Secret (or set HUBSPOT_CLIENT_SECRET env var)")
    parser.add_argument("-p", "--path", default="/api/hubspot/action", help="API endpoint path (default: /api/hubspot/action)")
    parser.add_argument("-w", "--workers", type=int, default=None, help="Max concurrent workers (default: rps * 2)")

    args = parser.parse_args()

    # --- Validate Input ---
    if args.rps <= 0:
        print("Error: RPS must be positive.", file=sys.stderr)
        sys.exit(1)
    if args.duration <= 0:
        print("Error: Duration must be positive.", file=sys.stderr)
        sys.exit(1)

    client_secret = args.secret or os.environ.get("HUBSPOT_CLIENT_SECRET")
    if not client_secret:
        print("Error: HubSpot Client Secret must be provided via --secret or HUBSPOT_CLIENT_SECRET env var.", file=sys.stderr)
        sys.exit(1)

    # --- Setup ---
    target_url = args.url.rstrip('/') # Remove trailing slash if present
    endpoint_path = args.path if args.path.startswith('/') else '/' + args.path
    num_requests = args.rps * args.duration
    max_workers = args.workers if args.workers else args.rps * 2 # Heuristic for workers

    print(f"--- Starting Load Test ---")
    print(f"Target URL:     {target_url}{endpoint_path}")
    print(f"Target RPS:     {args.rps}")
    print(f"Duration:       {args.duration} seconds")
    print(f"Total Requests: {num_requests}")
    print(f"Max Workers:    {max_workers}")
    print(f"Signature Ver:  {SIGNATURE_VERSION}")
    print(f"--------------------------")

    results = []
    success_count = 0
    failure_count = 0
    latencies = []

    # Use a session for connection pooling
    with requests.Session() as session:
        # Use ThreadPoolExecutor for concurrency
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            start_test_time = time.monotonic()
            futures = []

            # Submit all jobs
            for i in range(num_requests):
                # Calculate ideal submission time to spread load
                ideal_submit_time = start_test_time + (i / args.rps)
                sleep_time = ideal_submit_time - time.monotonic()
                if sleep_time > 0:
                    time.sleep(sleep_time)

                futures.append(executor.submit(send_request, session, target_url, endpoint_path, client_secret))
                if (i + 1) % args.rps == 0 : # Print progress roughly every second
                     print(f"Submitted {i+1}/{num_requests} requests...")

            print(f"All {num_requests} requests submitted. Waiting for completion...")

            # Process results as they complete
            for future in as_completed(futures):
                try:
                    status, latency, error = future.result()
                    results.append((status, latency, error))
                    if status == 204 and error is None: # Assuming 204 No Content is success
                        success_count += 1
                        latencies.append(latency)
                    else:
                        failure_count += 1
                        if error:
                            print(f"Request failed: Status={status}, Error={error}", file=sys.stderr)
                        else:
                             print(f"Request failed: Status={status} (Expected 204)", file=sys.stderr)

                except Exception as exc:
                    print(f'Request generated an exception: {exc}', file=sys.stderr)
                    failure_count += 1
                    results.append((None, 0, str(exc))) # Record failure

    end_test_time = time.monotonic()
    total_time = end_test_time - start_test_time

    # --- Report Results ---
    print(f"\n--- Test Finished ---")
    print(f"Total Time:      {total_time:.2f} seconds")
    print(f"Requests Sent:   {len(results)}")
    print(f"Success (204):   {success_count}")
    print(f"Failures:        {failure_count}")

    if latencies:
        avg_latency = statistics.mean(latencies) * 1000  # milliseconds
        median_latency = statistics.median(latencies) * 1000 # milliseconds
        min_latency = min(latencies) * 1000 # milliseconds
        max_latency = max(latencies) * 1000 # milliseconds
        print(f"Avg Latency:     {avg_latency:.2f} ms")
        print(f"Median Latency:  {median_latency:.2f} ms")
        print(f"Min Latency:     {min_latency:.2f} ms")
        print(f"Max Latency:     {max_latency:.2f} ms")
    else:
        print("Avg Latency:     N/A (No successful requests)")

    achieved_rps = success_count / total_time if total_time > 0 else 0
    print(f"Achieved RPS:    {achieved_rps:.2f} (based on successful requests)")
    print(f"---------------------")

    if failure_count > 0:
        print(f"\nNote: {failure_count} requests failed. Check logs for details.", file=sys.stderr)

if __name__ == "__main__":
    # Optional: Check ulimit if running high RPS on Linux/macOS
    # try:
    #     import resource
    #     soft_limit, hard_limit = resource.getrlimit(resource.RLIMIT_NOFILE)
    #     print(f"System open file limit (soft/hard): {soft_limit}/{hard_limit}")
    #     if soft_limit < max_workers * 2: # Heuristic check
    #         print(f"Warning: System open file limit ({soft_limit}) might be too low for {max_workers} workers. Consider increasing with 'ulimit -n'.", file=sys.stderr)
    # except ImportError:
    #     pass # resource module not available on Windows

    main()
