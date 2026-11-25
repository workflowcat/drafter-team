"""Chat-template encoding for local helpers. Task prompts and generation rules stay with callers."""


def encode(model, messages):
    """Use the template's start token and preserve the model-specific empty reasoning suffix."""
    text = model.tok.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
    if "<think>" in (model.tok.chat_template or "") and "Instruct-2507" not in model.repo:
        text += "<think>\n\n</think>\n\n"
    return model.tok.encode(text, add_special_tokens=False)
