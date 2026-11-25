from pathlib import Path


def agent_src() -> Path:
    """The agent's CMake project dir (`CMakeLists.txt` and the `.mm` sources), shipped as package data."""
    return Path(__file__).parent / "agent"
