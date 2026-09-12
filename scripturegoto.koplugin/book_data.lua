-- Maps churchofjesuschrist.org/study/scriptures/<volume>/<book-slug>/<chapter>
-- URL segments to human-readable book names, grouped by volume slug.
-- Volumes are configured with their own target EPUB in main.lua.
--
-- BOOK_VOLUME_BY_NAME (built below, keyed by lowercased canonical book name)
-- lets non-LDS providers - which link by plain English book name rather than
-- an LDS slug - figure out which "volume" (and therefore which configured
-- EPUB) a book belongs to, reusing the same ot/nt tables.
local BOOK_DATA = {
    ot = {
        gen = "Genesis", ex = "Exodus", lev = "Leviticus", num = "Numbers",
        deut = "Deuteronomy", josh = "Joshua", judg = "Judges", ruth = "Ruth",
        ["1-sam"] = "1 Samuel", ["2-sam"] = "2 Samuel",
        ["1-kgs"] = "1 Kings", ["2-kgs"] = "2 Kings",
        ["1-chr"] = "1 Chronicles", ["2-chr"] = "2 Chronicles",
        ezra = "Ezra", neh = "Nehemiah", esth = "Esther", job = "Job",
        ps = "Psalms", prov = "Proverbs", eccl = "Ecclesiastes", song = "Song of Solomon",
        isa = "Isaiah", jer = "Jeremiah", lam = "Lamentations", ezek = "Ezekiel",
        dan = "Daniel", hosea = "Hosea", joel = "Joel", amos = "Amos",
        obad = "Obadiah", jonah = "Jonah", micah = "Micah", nahum = "Nahum",
        hab = "Habakkuk", zeph = "Zephaniah", hag = "Haggai", zech = "Zechariah",
        mal = "Malachi",
    },
    nt = {
        matt = "Matthew", mark = "Mark", luke = "Luke", john = "John",
        acts = "Acts", rom = "Romans",
        ["1-cor"] = "1 Corinthians", ["2-cor"] = "2 Corinthians",
        gal = "Galatians", eph = "Ephesians", philip = "Philippians",
        col = "Colossians",
        ["1-thes"] = "1 Thessalonians", ["2-thes"] = "2 Thessalonians",
        ["1-tim"] = "1 Timothy", ["2-tim"] = "2 Timothy",
        titus = "Titus", philem = "Philemon", heb = "Hebrews", james = "James",
        ["1-pet"] = "1 Peter", ["2-pet"] = "2 Peter",
        ["1-jn"] = "1 John", ["2-jn"] = "2 John", ["3-jn"] = "3 John",
        jude = "Jude", rev = "Revelation",
    },
    bofm = {
        ["1-ne"] = "1 Nephi", ["2-ne"] = "2 Nephi", jacob = "Jacob",
        enos = "Enos", jarom = "Jarom", omni = "Omni",
        ["w-of-m"] = "Words of Mormon", mosiah = "Mosiah", alma = "Alma",
        hel = "Helaman", ["3-ne"] = "3 Nephi", ["4-ne"] = "4 Nephi",
        morm = "Mormon", ether = "Ether", moro = "Moroni",
    },
    -- Doctrine and Covenants is cited as "section:verse" (e.g. "D&C 88:103"),
    -- but on churchofjesuschrist.org it's just one "book" ("dc") whose
    -- "chapter" is the section number.
    ["dc-testament"] = {
        dc = "Doctrine and Covenants",
        od = "Official Declaration",
    },
    pgp = {
        moses = "Moses", abr = "Abraham",
        ["js-m"] = "Joseph Smith-Matthew", ["js-h"] = "Joseph Smith-History",
        ["a-of-f"] = "Articles of Faith",
    },
}

BOOK_DATA.BOOK_VOLUME_BY_NAME = {}
for _, volume in ipairs{ "ot", "nt", "bofm", "dc-testament", "pgp" } do
    for _, book_name in pairs(BOOK_DATA[volume]) do
        BOOK_DATA.BOOK_VOLUME_BY_NAME[book_name:lower()] = { volume = volume, name = book_name }
    end
end

return BOOK_DATA
