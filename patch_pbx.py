with open("apps/macos/KlarityApp.xcodeproj/project.pbxproj", "r") as f:
    text = f.read()

file_ref_id = "AAAA0000000000000000000A"
build_file_id = "BBBB0000000000000000000B"
group_id = "CCCC0000000000000000000C"

file_ref_line = f"\t\t{file_ref_id} /* ActionItemsView.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ActionItemsView.swift; sourceTree = \"<group>\"; }};\n"
build_file_line = f"\t\t{build_file_id} /* ActionItemsView.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* ActionItemsView.swift */; }};\n"

group_str = f"""\t\t{group_id} /* ActionItems */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{file_ref_id} /* ActionItemsView.swift */,
\t\t\t);
\t\t\tpath = ActionItems;
\t\t\tsourceTree = "<group>";
\t\t}};
"""

text = text.replace("/* End PBXBuildFile section */", build_file_line + "/* End PBXBuildFile section */")
text = text.replace("/* End PBXFileReference section */", file_ref_line + "/* End PBXFileReference section */")
text = text.replace("/* End PBXGroup section */", group_str + "/* End PBXGroup section */")
text = text.replace("4B53D2D8CE73A23CC54E1DE6 /* Home */,", f"4B53D2D8CE73A23CC54E1DE6 /* Home */,\n\t\t\t\t{group_id} /* ActionItems */,")
text = text.replace("BCE72884D9DF2A4747F1ABEB /* PeopleView.swift in Sources */,", f"BCE72884D9DF2A4747F1ABEB /* PeopleView.swift in Sources */,\n\t\t\t\t{build_file_id} /* ActionItemsView.swift in Sources */,")

with open("apps/macos/KlarityApp.xcodeproj/project.pbxproj", "w") as f:
    f.write(text)
print("Patched.")
