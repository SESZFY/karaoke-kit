import os
import runpy
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)
os.chdir(HERE)
runpy.run_path(os.path.join(HERE, "main_reflow.py"), run_name="__main__")