# :stt_live drives the real Whisper model (Bumblebee + EXLA + model
# download + ffmpeg); run explicitly with: mix test --only stt_live
ExUnit.start(exclude: [:stt_live])
