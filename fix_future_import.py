import os
import glob

# For all files in backend/app/**/*.py
for root, _, files in os.walk("/Users/rahulmohandas/Documents/Projects/KlarityApp/backend/app"):
    for file in files:
        if file.endswith(".py"):
            filepath = os.path.join(root, file)
            with open(filepath, "r") as f:
                lines = f.readlines()
                
            future_idx = -1
            opt_idx = -1
            for i, line in enumerate(lines):
                if line.startswith("from __future__ import"):
                    future_idx = i
                elif line.startswith("from typing import Optional"):
                    opt_idx = i
            
            if future_idx != -1 and opt_idx != -1 and opt_idx < future_idx:
                # Need to swap so future is first
                opt_line = lines.pop(opt_idx)
                # find first non-comment, non-docstring, non-future line
                insert_idx = 0
                for i, line in enumerate(lines):
                    if line.startswith("from __future__"):
                        insert_idx = i + 1
                lines.insert(insert_idx, opt_line)
                
                with open(filepath, "w") as f:
                    f.writelines(lines)
                print(f"Fixed ordering in {filepath}")
