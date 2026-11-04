-- homelab bar widget. polls bellona's summary API; the token is the same
-- agenix secret the API validates (homelab-api-token).
local TOKEN = "bd76faabd3e4907d6472fc7789ff1aafe0b41003e5e17377"

function update()
  noctalia.setUpdateInterval(15000)
  barWidget.setGlyph("activity")
  noctalia.http({
    url = "http://192.168.2.59:8091/summary",
    headers = { "Authorization: Bearer " .. TOKEN },
  }, function(res)
    if not res.ok then
      barWidget.setText("homelab ?")
      return
    end
    local data = noctalia.json.decode(res.body)
    if not data then
      barWidget.setText("homelab ?")
      return
    end
    local line = "—"
    if data.sparks and #data.sparks > 0 then
      line = data.sparks[1].line
    end
    if data.torrents and data.torrents.line then
      line = line .. " · " .. data.torrents.line
    end
    barWidget.setText(line)
  end)
end

function onClick()
  noctalia.runAsync({ "xdg-open", "https://home.packet.dog" })
end
