import re
import glob
import os

for root, _, files in os.walk("/Users/rahulmohandas/Documents/Projects/KlarityApp/backend/app"):
    for file in files:
        if file.endswith(".py"):
            filepath = os.path.join(root, file)
            with open(filepath, "r") as f:
                content = f.read()
            
            old_content = content
            
            # replace Name | None with Optional[Name]
            # but it could be int | None, str | None, dict | None, float | None, etc.
            # Handle standard return types and annotations
            # Regex to match: : type | None = None
            content = re.sub(r'([a-zA-Z0-9_\[\]]+)\s*\|\s*None', r'Optional[\1]', content)
            
            if content != old_content:
                if 'from typing import ' in content and 'Optional' not in content:
                    content = content.replace('from typing import ', 'from typing import Optional, ', 1)
                elif 'from typing import ' not in content:
                    # just put it at top 
                    content = 'from typing import Optional\n' + content
                with open(filepath, "w") as f:
                    f.write(content)
                print(f"Fixed {filepath}")
