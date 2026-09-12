-- Expands a raw verse-list/range string (e.g. "12-14,16-17" or "21, 22")
-- into a deduplicated, sorted list of individual verse numbers. Shared by
-- providers/reference_text.lua (parsing free text) and providers/lds.lua
-- (parsing churchofjesuschrist.org's "id=p5-p7" / "id=p5,p7" style verse
-- ids, once the leading "p"s are stripped).
local function expand(raw)
    local seen, verses = {}, {}
    for token in raw:gmatch("[^,]+") do
        local a, b = token:match("^%s*(%d+)%s*%-%s*(%d+)%s*$")
        if a then
            a, b = tonumber(a), tonumber(b)
            if b < a then a, b = b, a end
            for v = a, b do
                if not seen[v] then seen[v] = true; table.insert(verses, v) end
            end
        else
            local single = token:match("%d+")
            if single then
                local v = tonumber(single)
                if not seen[v] then seen[v] = true; table.insert(verses, v) end
            end
        end
    end
    table.sort(verses)
    return verses
end

return { expand = expand }
