import base64
from pathlib import Path

html = """
<!DOCTYPE html>
<html>
<head>
    <script src="https://www.geogebra.org/apps/deployggb.js"></script>
</head>
<body>
<div id="ggb-element"></div>

<script>

const todos = [
"""
ntodos = 0
for path in reversed(list(Path("showcase").glob("./*.ggb"))):
    ggb = path.read_bytes()
    b64 = base64.b64encode(ggb).decode()
    html += f""" ["{path.name}", "{b64}"], """
    ntodos += 1

html += """
];
function createApplet(i) {
if (i >= todos.length) return;
const ggb = new GGBApplet({
    appName: "classic",
    width: 1600,
    height: 1200,

    appletOnLoad(api) {
        api.setBase64(todos[i][1], () => { console.log("objects:", api.getObjectNumber()); api.writePNGtoFile(todos[i][0], 1, false, 300); document.getElementById("ggb-element").innerHTML = ""; createApplet(i+1);
        });
    }
}, true);
ggb.inject("ggb-element");
}
"""

html += """
window.addEventListener("load", () => {
    createApplet(0);
});
</script>
</body>
</html>
"""

Path("export.html").write_text(html)
