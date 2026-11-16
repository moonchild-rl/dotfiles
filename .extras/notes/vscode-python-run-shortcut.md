# Run a Python file in VS Code with Ctrl+R

With this shortcut set up, Ctrl+R runs the active Python file in VS Code's terminal, using the interpreter selected by the Microsoft Python extension. It avoids the debugger/configuration picker. The keys are easy to find by touch while typing.

## Set up on any computer

1. Install the **Python** extension by Microsoft in VS Code.
2. Press **Ctrl+Shift+P** and open **Preferences: Open Keyboard Shortcuts (JSON)**.
3. Add this object inside the existing `[...]` array in `keybindings.json` (separate it from other entries with a comma):

   ```json
   {
     "key": "ctrl+r",
     "command": "python.execInTerminal",
     "when": "editorTextFocus && editorLangId == python"
   }
   ```

4. Save the file. Open a `.py` file, place the cursor in the editor, and press **Ctrl+R**.

VS Code normally uses Ctrl+R for **Open Recent**. This binding replaces that action only while the cursor is in a Python editor. Elsewhere, Ctrl+R keeps its usual behavior. If the wrong Python is used, run **Python: Select Interpreter** from the Command Palette.

References: [VS Code Python run guide](https://code.visualstudio.com/docs/python/run) · [VS Code keyboard shortcuts](https://code.visualstudio.com/docs/configure/keybindings)
