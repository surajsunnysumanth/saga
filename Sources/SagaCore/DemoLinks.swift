import Foundation

/// Real, public music and video links used by the synthetic archive, so the Music sections
/// and Wrapped soundtrack open something that actually exists. Every URL here was checked
/// once at authoring time (Spotify and YouTube through their public oEmbed endpoints, Apple
/// Music through a plain HTTP request); generating the demo never touches the network.
///
/// Nothing here is tied to a person: these are public catalogue pages, picked for a mixed
/// Indian and international listening register.
enum DemoLinks {
    static let all: [String] = [
        "https://open.spotify.com/track/7rjGMtaeY9vJs6OfDFVrXy",   // Mera Hua (Arijit Singh)
        "https://open.spotify.com/track/2UVxQoXyJQs98RrXJoLoZK",   // Dhal Jaun Main
        "https://open.spotify.com/track/3CNntsdd594RzUkNtFSOkI",   // Khairiyat
        "https://open.spotify.com/track/2U0BLmYoSESYOdwMxW2yA9",   // Chal Ghar Chalen
        "https://open.spotify.com/track/1QLFwInBAT0ZtfMihTaCst",   // Dola Dola
        "https://open.spotify.com/track/4vdWpGi551Gm0wSHIOIBQz",   // Piya Milenge
        "https://open.spotify.com/track/7xEx1XD3Sue89o561tV29w",   // Mental Manadhil
        "https://open.spotify.com/track/5ZRC8olKigutRRrExSKpTI",   // Tu Hi Re (live)
        "https://open.spotify.com/track/0apzXaVbunSocMhyBEGDPy",   // Pookkalae Sattru Oyivedungal
        "https://open.spotify.com/track/2qI0dxrLFzm5oCgjiYc265",   // for your time — Prateek Kuhad
        "https://open.spotify.com/track/3FTRSa9mWB3kKx2jkhUAN3",   // Tum Jab Paas
        "https://open.spotify.com/track/1TkyDEdjiUuYhoMkxdZCiO",   // Tere Hi Hum
        "https://open.spotify.com/track/6uh25H3MfizwNyfzyDswZs",   // If I Cannot Be Yours
        "https://open.spotify.com/track/6WrUT7FOAlDscRWU7ndmyd",   // Viva La Vida
        "https://open.spotify.com/track/7wBrglFVTNCcW6IhdgBkm1",   // Paradise
        "https://open.spotify.com/track/2wbrV2GSC6q7v5R0GJiWTH",   // A Sky Full of Stars
        "https://open.spotify.com/track/3jPz4KzWN9TihclFEikFyi",   // ALL MY LOVE
        "https://open.spotify.com/track/4rDWlnnRcziZ0dJM7T32wG",   // Everyday Life
        "https://open.spotify.com/track/0HthhINsVIizMve20VhD0D",   // Speed of Sound
        "https://open.spotify.com/track/51Gk1czQl7NjX0jHwawO1G",   // Yeh Pal
        "https://open.spotify.com/track/2xAH9fWprChfOqIdfXbw5Y",   // Kahaan Ho Tum
        "https://open.spotify.com/track/13beCSnMBaDaJEjVfOMkBy",   // Atak Gaya (lofi)
        "https://open.spotify.com/track/5IqYN8MAOkPpomcKpRUYJF",   // Apur Paayer Chhaap
        "https://open.spotify.com/track/06rKDymdyeHc3MTpIXhy5o",   // Anbil Avan
        "https://open.spotify.com/track/20V1lKkDO8ejYvmOElRHsF",   // Jai Ho!
        "https://open.spotify.com/track/4sO9tnvCH3DJZ3AAXoixjd",   // Kahaan Ho Tum (alt master)
        "https://open.spotify.com/track/7eTy1IzCaICfm6JYy1BV4u",   // with you/for you
        "https://open.spotify.com/track/7G8aa1oAZYrWHpmu9JqnH4",   // Thai Mannai Vanakkam
        "https://www.youtube.com/watch?v=z0mVvLBAVg0",             // Arijit Singh — Yeh Kaisi Majboori Hai
        "https://www.youtube.com/watch?v=it1FyrYPAcM",             // Arijit Singh — Tum Se
        "https://www.youtube.com/watch?v=sqIYOj7eVKw",             // Tera Hone Laga Hoon
        "https://www.youtube.com/watch?v=NLIpz3MdXeg",             // Tere Naam Sa
        "https://www.youtube.com/watch?v=U-KL-VWSCbI",             // Tum Hi Ho
        "https://www.youtube.com/watch?v=waY2Zk1RjRY",             // Phir Le Aaya Dil
        "https://www.youtube.com/watch?v=RUiRBcrYsjE",             // Jo Tere Sang
        "https://www.youtube.com/watch?v=Tmu6bKeIfGM",             // Janam Janam
        "https://www.youtube.com/watch?v=Wnaj5tfGjK8",             // Dil Haareya
        "https://www.youtube.com/watch?v=poD6eFLTiGY",             // Tu Samjhe Na
        "https://www.youtube.com/watch?v=q7OUFE3dw6E",             // Aaromale (Vinnaithaandi Varuvaayaa)
        "https://www.youtube.com/watch?v=a5mBVidWFkU",             // Aabhi Jaa
        "https://www.youtube.com/watch?v=NUUNvCNJt3E",             // I Miss You Da
        "https://www.youtube.com/watch?v=_f8dMFzYRCE",             // Aaruyirae (Guru)
        "https://www.youtube.com/watch?v=mYzvmt36S_c",             // Jodi Jodi (Guru)
        "https://www.youtube.com/watch?v=hxNWiamDSK4",             // Taxi Taxi
        "https://www.youtube.com/watch?v=mCyC1LoFzTU",             // Mayya Mayya
        "https://www.youtube.com/watch?v=DWQekmnj1ZI",             // Naan Epoudhu
        "https://www.youtube.com/watch?v=ZKSRnDH8-lw",             // Nanare (Guru)
        "https://www.youtube.com/watch?v=bnSeLxfs6H8",             // Ae Nazneen Suno Na
        "https://www.youtube.com/watch?v=dvgZkm1xWPE",             // Coldplay — Viva La Vida
        "https://www.youtube.com/watch?v=yKNxeF4KMsY",             // Coldplay — Yellow
        "https://www.youtube.com/watch?v=1G4isv_Fylg",             // Coldplay — Paradise
        "https://www.youtube.com/watch?v=sBzrzS1Ag_g",             // Tame Impala — The Less I Know The Better
        "https://www.youtube.com/watch?v=5NV6Rdv1a3I",             // Daft Punk — Get Lucky
        "https://www.youtube.com/watch?v=TUVcZfQe-Kw",             // Dua Lipa — Levitating
        "https://youtu.be/q7OUFE3dw6E",                            // shared as a short link
        "https://youtu.be/U-KL-VWSCbI",
        "https://youtu.be/dvgZkm1xWPE",
        "https://music.apple.com/in/song/ranjha/1882965642",       // Diljit Dosanjh — Ranjha
        "https://music.apple.com/in/song/hass-hass/1710378962",    // Diljit Dosanjh — Hass Hass
        "https://music.apple.com/in/song/water/1796419829",        // Diljit Dosanjh — Water
        "https://music.apple.com/in/song/love-ya/1724181551",      // Diljit Dosanjh — Love Ya
        "https://music.apple.com/in/song/heer/1792974826",         // Diljit Dosanjh — Heer
        "https://music.apple.com/in/song/bahana/1821670381",       // Diljit Dosanjh — Bahana
        "https://music.apple.com/in/song/mombattiye/1757386826",   // Diljit Dosanjh — Mombattiye
        "https://music.apple.com/in/album/arijit-singh-india-tour-hits/1657154310",
        "https://music.apple.com/in/album/arijit-singh-sad-love-songs/1743183807",
        "https://music.apple.com/in/album/long-drive-bollywood-mix-arijit-singh/1697478991",
        "https://music.apple.com/in/album/hits-of-arijit-singh/1638921433",
        "https://music.apple.com/in/album/saware-from-phantom/1321918416?i=1321918448",
        "https://music.apple.com/in/song/morni/1894792753",        // Diljit Dosanjh — Morni
    ]

    /// A per-chat rotation: each conversation leans on its own slice, so the archive does not
    /// read as one playlist pasted everywhere. Every third slot is a favourite that comes back,
    /// which is what "on repeat" and "you both shared it" count.
    static func rotation(for chatIndex: Int, count: Int) -> [String] {
        guard !all.isEmpty, count > 0 else { return [] }
        var rng = DemoRandom(seed: 0xA17E_0000 &+ UInt64(chatIndex) * 7_919)
        var bag = all
        rng.shuffle(&bag)
        let favourites = Array(bag.prefix(max(2, count / 3)))
        var out: [String] = []
        var next = 0
        for i in 0..<count {
            if i % 3 == 2 {
                out.append(favourites[(i / 3) % favourites.count])
            } else {
                out.append(bag[next % bag.count])
                next += 1
            }
        }
        return out
    }
}
