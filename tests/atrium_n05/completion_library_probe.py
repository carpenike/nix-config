"""Diagnose the native completion decoder without auth, DB, or external network."""

import argparse
import json
import secrets
import subprocess
from pathlib import Path

from supervisor import ROOT, inventory, load_harness, ready


PROBE = """
import asyncio,importlib.metadata,json,logging,os,pathlib,secrets,sys,threading,traceback
from http.server import ThreadingHTTPServer
os.environ["LITELLM_LOCAL_MODEL_COST_MAP"]="True"
os.environ["LITELLM_TELEMETRY"]="False"
os.environ["DO_NOT_TRACK"]="1"
logging.disable(logging.CRITICAL)
namespace={"__name__":"n05_provider"}
exec(compile(json.loads(sys.stdin.readline()),"provider.py","exec"),namespace)
key=secrets.token_urlsafe(32)
server=ThreadingHTTPServer(("127.0.0.1",0),namespace["handler"](key,secrets.token_urlsafe(32)))
thread=threading.Thread(target=server.serve_forever,daemon=True)
thread.start()
import litellm
litellm.suppress_debug_info=True
from litellm.caching.caching import Cache
litellm.cache=Cache(type="local",ttl=600)
async def exercise():
 rows=[]
 for stream in (False,True):
  try:
   response=await litellm.atext_completion(
    model="openai/fixture-family",prompt="Synthetic decoder probe.",stream=stream,
    api_base=f"http://127.0.0.1:{server.server_port}/v1",api_key=key,
    max_tokens=4,num_retries=0,caching=True)
   if stream:
    output=[]
    async for chunk in response:
     text=chunk.choices[0].text
     assert text is None or isinstance(text,str)
     output.append(text or "")
    output="".join(output)
   else:
    output=response.choices[0].text
   rows.append({"stream":stream,"status":"passed","expected_output":output=="fixture-ok-n05"})
  except Exception as error:
   chain=[]
   seen=set()
   while error is not None and id(error) not in seen and len(chain)<8:
    seen.add(id(error))
    chain.append({"type":type(error).__name__,"frames":[
      {"file":frame.filename.split("/site-packages/",1)[-1]
       if "/site-packages/" in frame.filename else pathlib.Path(frame.filename).name,
       "function":frame.name,"line":frame.lineno}
      for frame in traceback.extract_tb(error.__traceback__)[-8:]]})
    error=error.__cause__ or error.__context__
   rows.append({"stream":stream,"status":"failed","exceptions":chain})
 return rows
try:
 rows=asyncio.run(exercise())
 print(json.dumps({"version":importlib.metadata.version("litellm"),"cases":rows}),flush=True)
finally:
 server.shutdown()
 server.server_close()
 thread.join(timeout=5)
"""


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--harness", required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    _, hashes = load_harness(args.harness)
    from harness.common import EvidenceWriter, PINS, require
    from harness.containers import Resources

    result = {
        "scope": "native-library decoder diagnostic, not N05 admission proof",
        "harness": hashes,
        "run_id": "n05-completion-library-" + secrets.token_hex(8),
    }
    output = args.evidence.resolve()
    require(
        output.is_relative_to(ROOT / "tests/atrium_n05/results"),
        "evidence_path_refused",
    )
    writer = EvidenceWriter(output, result)
    resources = Resources(result["run_id"], result, writer.publish)
    before = ready(resources)
    try:
        host = json.loads(resources.command(["info", "--format", "json"]))
        arch = host["host"]["arch"]
        image = resources.image(PINS["litellm"]["image"], "linux/" + arch)
        identifier = resources.create(
            "decoder",
            image["image_id"],
            "python",
            ["-B", "-c", PROBE],
            memory="768m",
            network=False,
        )
        completed = subprocess.run(
            [
                *resources.prefix_command,
                "start",
                "--attach",
                "--interactive",
                identifier,
            ],
            input=json.dumps((ROOT / "tests/atrium_n05/provider.py").read_text())
            + "\n",
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=45,
        )
        require(completed.returncode == 0, "decoder_probe_process_failed")
        result["observation"] = json.loads(completed.stdout)
        require(result["observation"]["version"] == "1.99.1", "native_version_mismatch")
        result["status"] = (
            "passed"
            if all(
                row["status"] == "passed" and row["expected_output"]
                for row in result["observation"]["cases"]
            )
            else "failed"
        )
    finally:
        resources.cleanup()
        result["foreign_resources_unchanged"] = inventory(resources) == before
        writer.publish()
    require(result["foreign_resources_unchanged"], "foreign_resource_changed")
    print(json.dumps(result["observation"], indent=2))
    return 0 if result["status"] == "passed" else 2


if __name__ == "__main__":
    raise SystemExit(main())
