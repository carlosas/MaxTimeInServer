-- Minimal test harness. Lua 5.1 compatible (PZ runs a 5.1-level interpreter).
local H = { cases = {}, failures = 0, passes = 0 }

function H.test(name, fn)
    table.insert(H.cases, { name = name, fn = fn })
end

local function fail(msg)
    error(msg, 3)
end

function H.assertEqual(actual, expected, what)
    if actual ~= expected then
        fail(string.format("%s: expected %s, got %s",
            what or "value", tostring(expected), tostring(actual)))
    end
end

function H.assertTrue(value, what)
    if not value then fail((what or "value") .. ": expected truthy, got " .. tostring(value)) end
end

function H.assertFalse(value, what)
    if value then fail((what or "value") .. ": expected falsy, got " .. tostring(value)) end
end

function H.assertNil(value, what)
    if value ~= nil then fail((what or "value") .. ": expected nil, got " .. tostring(value)) end
end

function H.assertMatch(text, pattern, what)
    if type(text) ~= "string" or not text:find(pattern) then
        fail(string.format("%s: expected a match for %q in %s",
            what or "text", pattern, tostring(text)))
    end
end

function H.run(label)
    local failed = {}
    for _, case in ipairs(H.cases) do
        local ok, err = pcall(case.fn)
        if ok then
            H.passes = H.passes + 1
        else
            H.failures = H.failures + 1
            table.insert(failed, { name = case.name, err = err })
        end
    end
    for _, f in ipairs(failed) do
        io.write(string.format("  FAIL %s\n        %s\n", f.name, tostring(f.err)))
    end
    io.write(string.format("%-14s %d passed, %d failed\n", label, H.passes, H.failures))
    if H.failures > 0 then os.exit(1) end
end

return H
