from fastapi import FastAPI

app = FastAPI(title="DevSecOps Pipeline Demo", version="1.0.0")


@app.get("/")
def root():
    return {"message": "DevSecOps Pipeline Running", "version": "1.0.0"}


@app.get("/health")
def health():
    return {"status": "healthy"}
